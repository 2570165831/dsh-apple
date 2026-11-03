//
//  ISHImageService.m
//  DSHPortC
//
//  ImageIO + CoreGraphics implementation of the raster operations DSH performs
//  through `sharp`. See the header for why the decode lives here; this file is
//  about how, and about the four details that took measurement rather than
//  guessing:
//
//    1. `kCGImagePropertyHasAlpha` is what a PNG reports; a JPEG never does.
//       That is the exact question `canPassThroughNormalization` asks, so it is
//       read rather than inferred from the container.
//    2. An ICC profile counts as retained metadata. Sharp reports `metadata.icc`
//       and DSH then re-encodes the image through a metadata-free sRGB pipeline
//       instead of passing the source through. Reproducing that rule is what
//       makes a phone photo lose its GPS block on the way to a model.
//    3. The re-encode itself writes NO metadata: the destination gets pixels
//       only, from a fresh 8-bit sRGB bitmap context. There is no EXIF/GPS/XMP/
//       IPTC/ICC block to inherit because none is ever copied in.
//    4. Alpha is kept by choosing PNG over JPEG. ImageIO on iOS has no WebP
//       ENCODER (it decodes WebP fine), and a lossless PNG keeps the same
//       property sharp's WebP fallback exists for: an alpha channel survives.
//

#import "ISHImageService.h"

#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

NSString *const ISHImageErrorInvalidImage = @"INVALID_IMAGE";
NSString *const ISHImageErrorTooManyPixels = @"IMAGE_TOO_MANY_PIXELS";
NSString *const ISHImageErrorDimensionTooLarge = @"IMAGE_DIMENSION_TOO_LARGE";
NSString *const ISHImageErrorEncodeFailed = @"ATTACHMENT_WRITE_FAILED";
NSString *const ISHImageErrorEmptyInput = @"INVALID_IMAGE";

/// The quality ladder DSH itself uses, so the size behaviour matches sharp's.
static const double kEncodingQualities[] = { 85.0, 75.0, 60.0 };
static const size_t kEncodingQualityCount = sizeof(kEncodingQualities) / sizeof(kEncodingQualities[0]);

/// How far a source shorter side may be shrunk for the pixel-budget probe.
///
/// `fullDecode` must prove the bytes decode without materialising the full
/// raster, so it renders a single small frame. 4096 is far above any probe's
/// needs and still bounded.
static const size_t kProbePixelSize = 4096;

@implementation ISHImageService

+ (instancetype)shared {
    static ISHImageService *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ISHImageService alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("dshportc.image", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - container facts

/// Map an ImageIO UTI to the media types DSH's attachment seam speaks.
///
/// The two `public.heic` / `public.heif` spellings are distinct UTIs and both
/// appear on real devices (a single-shot photo is `public.heic`, a Live Photo's
/// still may be `public.heif`). GIF and WebP keep their own types so the
/// existing "animated" and "alpha" handling still applies to them.
- (nullable NSString *)mediaTypeOfUTI:(nullable NSString *)uti {
    if (uti.length == 0) return nil;
    NSString *lower = uti.lowercaseString;
    if ([lower isEqualToString:@"public.jpeg"] || [lower isEqualToString:@"public.jpeg-2000"]) return @"image/jpeg";
    if ([lower isEqualToString:@"public.png"]) return @"image/png";
    if ([lower isEqualToString:@"public.heic"] || [lower isEqualToString:@"public.heif"]) return @"image/heic";
    if ([lower isEqualToString:@"com.compuserve.gif"]) return @"image/gif";
    if ([lower isEqualToString:@"org.webmproject.webp"]) return @"image/webp";
    if ([lower isEqualToString:@"public.tiff"]) return @"image/tiff";
    return nil;
}

- (nullable NSString *)mediaTypeOfData:(NSData *)data {
    if (data.length == 0) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef) data, NULL);
    if (source == NULL) return nil;
    // `CGImageSourceGetType` follows the Get rule: the CFString is NOT owned by
    // the caller, so it must not be transferred to ARC.
    NSString *type = (__bridge NSString *) CGImageSourceGetType(source);
    NSString *answer = [self mediaTypeOfUTI:type];
    CFRelease(source);
    return answer;
}

/// Read one dictionary out of a properties bag, tolerating a missing bag.
static NSDictionary *sub(NSDictionary *bag, CFStringRef key) {
    id value = bag[(__bridge NSString *) key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

/// EXIF tags that describe the pixels rather than the capture.
///
/// ImageIO writes these three into every JPEG it produces, so treating them as
/// "retained metadata" would make this service refuse its own output. They carry
/// no capture or location information: the dimensions are already the answer's
/// `width`/`height`, and `ColorSpace` is already its `space`.
static BOOL isPixelDescriptionExifKey(NSString *key) {
    return [key isEqualToString:@"PixelXDimension"]
        || [key isEqualToString:@"PixelYDimension"]
        || [key isEqualToString:@"ColorSpace"];
}

/// TIFF tags that describe resolution only, which every JFIF JPEG carries and
/// which libvips does not report as metadata at all.
///
/// `Orientation` is deliberately NOT here: sharp reports it, DSH therefore
/// re-encodes an oriented source instead of passing it through, and that is the
/// only way a rotated phone photo reaches the model upright.
static BOOL isResolutionOnlyTiffKey(NSString *key) {
    return [key isEqualToString:@"XResolution"]
        || [key isEqualToString:@"YResolution"]
        || [key isEqualToString:@"ResolutionUnit"]
        || [key isEqualToString:@"TileWidth"]
        || [key isEqualToString:@"TileLength"];
}

/// Whether the source carries an XMP packet.
///
/// ImageIO exposes XMP only through `CGImageSourceCopyMetadataAtIndex`, never as
/// a key in the properties bag — a source can hold a full XMP packet (GPS,
/// capture date, Photoshop history) and look perfectly clean in `properties`.
/// Measured: a HEIC from `sips` reports the `iio:hasXMP` tag here and nothing at
/// all in `properties`.
static BOOL sourceCarriesXMP(CGImageSourceRef source) {
    CGImageMetadataRef metadata = CGImageSourceCopyMetadataAtIndex(source, 0, NULL);
    if (metadata == NULL) return NO;
    BOOL found = NO;
    CFArrayRef tags = CGImageMetadataCopyTags(metadata);
    if (tags != NULL) {
        for (CFIndex index = 0; index < CFArrayGetCount(tags) && !found; index++) {
            CGImageMetadataTagRef tag = (CGImageMetadataTagRef) CFArrayGetValueAtIndex(tags, index);
            if (tag == NULL) continue;
            CFStringRef prefix = CGImageMetadataTagCopyPrefix(tag);
            NSString *name = prefix != NULL ? (__bridge_transfer NSString *) prefix : nil;
            // `xmp:` is a real XMP namespace; `iio:hasXMP` is ImageIO's own
            // marker that a packet exists even when no tag was individually
            // decoded.
            if ([name isEqualToString:@"xmp"]) found = YES;
            CFStringRef tagName = CGImageMetadataTagCopyName(tag);
            if (tagName != NULL) {
                NSString *leaf = (__bridge_transfer NSString *) tagName;
                if ([leaf isEqualToString:@"hasXMP"]) found = YES;
            }
        }
        CFRelease(tags);
    }
    CFRelease(metadata);
    return found;
}

/// Whether a properties bag carries anything DSH's normalisation path would strip.
///
/// DSH's own rule (`carriesRetainedMetadata` in `dsh-attachment-local`) is
/// derived from what libvips reports: any EXIF, XMP, IPTC, ICC or Photoshop
/// block, a comments block, or an explicit orientation tag. This restates that
/// rule in ImageIO's vocabulary, and it has to agree with two hard constraints:
///
///   * A source with any of it is RE-ENCODED rather than passed through
///     byte-identically. That is what removes a phone photo's GPS block.
///   * The RE-ENCODED output must itself report NO retained metadata, because
///     `verifyNormalizedImage` re-probes what this service just produced and
///     fails the attachment if the answer says otherwise. So the keys ImageIO
///     adds by itself — pixel dimensions, an sRGB profile name, JFIF density —
///     are descriptions of the pixels, not leftovers, and are excluded.
///
/// A non-sRGB profile (Display P3, Adobe RGB) IS retained metadata: the pixels
/// are not what `space` claims, so the image must be converted.
// Defined below; declared here because the check that follows calls it.
static BOOL profileIsSRGB(NSString *profileName);

static BOOL carriesRetainedMetadata(CGImageSourceRef source,
                                   NSDictionary *properties,
                                   NSDictionary *exif,
                                   NSDictionary *tiff) {
    if (sub(properties, kCGImagePropertyGPSDictionary) != nil) return YES;
    if (sub(properties, kCGImagePropertyIPTCDictionary) != nil) return YES;
    if (sub(properties, kCGImageProperty8BIMDictionary) != nil) return YES;
    if (sub(properties, kCGImagePropertyMakerAppleDictionary) != nil) return YES;
    if (sourceCarriesXMP(source)) return YES;
    NSString *profileName = properties[(__bridge NSString *) kCGImagePropertyProfileName];
    if (profileName != nil && !profileIsSRGB(profileName)) return YES;
    if (exif != nil) {
        for (NSString *key in exif.allKeys) {
            if (!isPixelDescriptionExifKey(key)) return YES;
        }
    }
    if (tiff != nil) {
        for (NSString *key in tiff.allKeys) {
            if (!isResolutionOnlyTiffKey(key)) return YES;
        }
    }
    return NO;
}

/// Whether a profile name is the standard sRGB profile (or the untagged default).
static BOOL profileIsSRGB(NSString *profileName) {
    if (profileName.length == 0) return YES;
    NSString *lower = profileName.lowercaseString;
    // "sRGB IEC61966-2.1" is what ImageIO names it; "sRGB" alone appears on
    // some sources. A Display P3 or Adobe RGB profile must NOT match.
    return [lower hasPrefix:@"srgb"];
}

/// The depth token DSH compares against `"uchar"`.
static NSString *depthToken(NSNumber *bitsPerComponent) {
    NSInteger bits = bitsPerComponent.integerValue;
    if (bits <= 8) return @"uchar";
    if (bits <= 16) return @"ushort";
    return @"float";
}

/// The colour-space token DSH compares against `"srgb"`.
///
/// Sharp reports the libvips interpretation. An 8-bit RGB frame is `"srgb"`
/// whatever profile is attached to it; 16-bit RGB is `"rgb16"`; grey is
/// `"b-w"`. A CMYK JPEG is `"cmyk"`, which DSH will then re-encode — correct,
/// because its stored contract is sRGB.
static NSString *spaceToken(NSNumber *bitsPerComponent, NSString *colorModel) {
    NSString *model = colorModel.uppercaseString;
    if ([model isEqualToString:@"RGB"]) return bitsPerComponent.integerValue > 8 ? @"rgb16" : @"srgb";
    if ([model isEqualToString:@"GRAY"]) return bitsPerComponent.integerValue > 8 ? @"grey16" : @"b-w";
    if ([model isEqualToString:@"CMYK"]) return @"cmyk";
    if ([model isEqualToString:@"LAB"]) return @"lab";
    return @"multiband";
}

/// Whether the container holds more than one frame (an animated GIF, a HEIC
/// image sequence, a multi-page TIFF).
static BOOL sourceIsAnimated(CGImageSourceRef source) {
    return CGImageSourceGetCount(source) > 1;
}

#pragma mark - probe

- (NSDictionary<NSString *, id> *)probeData:(NSData *)data
                                 fullDecode:(BOOL)fullDecode
                                  maxPixels:(long long)maxPixels
                               maxDimension:(long long)maxDimension {
    if (data.length == 0) {
        return @{ @"ok": @NO, @"code": ISHImageErrorEmptyInput, @"message": @"Image is empty." };
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef) data, NULL);
    if (source == NULL) {
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Unsupported or malformed image data." };
    }

    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    if (![properties isKindOfClass:[NSDictionary class]]) {
        CFRelease(source);
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Unsupported or malformed image data." };
    }

    NSNumber *widthValue = properties[(__bridge NSString *) kCGImagePropertyPixelWidth];
    NSNumber *heightValue = properties[(__bridge NSString *) kCGImagePropertyPixelHeight];
    if (widthValue == nil || heightValue == nil) {
        CFRelease(source);
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Image header carries no pixel dimensions." };
    }

    long long width = widthValue.longLongValue;
    long long height = heightValue.longLongValue;
    if (width <= 0 || height <= 0) {
        CFRelease(source);
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Image header carries non-positive pixel dimensions." };
    }

    // Limits are checked against the header, before any pixel is decoded: an
    // oversized source must cost a refusal, not 250 MB and a jetsam kill.
    if (maxPixels > 0 && width * height > maxPixels) {
        CFRelease(source);
        return @{
            @"ok": @NO,
            @"code": ISHImageErrorTooManyPixels,
            @"message": @"Image exceeds the configured decoded-pixel limit.",
            @"width": @(width),
            @"height": @(height),
        };
    }
    if (maxDimension > 0 && MAX(width, height) > maxDimension) {
        CFRelease(source);
        return @{
            @"ok": @NO,
            @"code": ISHImageErrorDimensionTooLarge,
            @"message": @"Image exceeds the configured per-side pixel limit.",
            @"width": @(width),
            @"height": @(height),
        };
    }

    NSDictionary *exif = sub(properties, kCGImagePropertyExifDictionary);
    NSDictionary *tiff = sub(properties, kCGImagePropertyTIFFDictionary);
    // Get rule again: borrow the type string, do not take ownership of it.
    NSString *mediaType = [self mediaTypeOfUTI:(__bridge NSString *) CGImageSourceGetType(source)];
    NSString *colorModel = properties[(__bridge NSString *) kCGImagePropertyColorModel];
    NSNumber *depth = properties[(__bridge NSString *) kCGImagePropertyDepth];
    NSNumber *hasAlpha = properties[(__bridge NSString *) kCGImagePropertyHasAlpha];
    BOOL animated = sourceIsAnimated(source);

    NSDictionary *answer = @{
        @"ok": @YES,
        @"mediaType": mediaType ?: @"",
        @"width": @(width),
        @"height": @(height),
        @"depth": depthToken(depth),
        @"space": spaceToken(depth, colorModel),
        @"hasAlpha": @(hasAlpha.boolValue),
        @"animated": @(animated),
        @"carriesMetadata": @(carriesRetainedMetadata(source, properties, exif, tiff)),
        @"orientation": tiff[(__bridge NSString *) kCGImagePropertyTIFFOrientation] ?: @0,
    };

    if (!fullDecode) {
        CFRelease(source);
        return answer;
    }

    // A corrupt or truncated payload often has a perfect header. The only honest
    // test is to decode something, so one down-sampled frame is rendered and
    // thrown away. `CGImageSourceCreateThumbnailAtIndex` does not need the full
    // raster in memory, which is what makes this safe on a phone.
    NSDictionary *options = @{
        (__bridge NSString *) kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *) kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *) kCGImageSourceThumbnailMaxPixelSize: @(kProbePixelSize),
        (__bridge NSString *) kCGImageSourceShouldCacheImmediately: @NO,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef) options);
    CFRelease(source);
    if (thumbnail == NULL) {
        return @{
            @"ok": @NO,
            @"code": ISHImageErrorInvalidImage,
            @"message": @"Unsupported or malformed image data.",
            @"width": @(width),
            @"height": @(height),
        };
    }
    CGImageRelease(thumbnail);
    return answer;
}

#pragma mark - encode

/// Draw one image into a fresh 8-bit premultiplied sRGB bitmap and hand back the
/// resulting `CGImage`.
///
/// Two things are deliberate:
///
///   * the colour space is sRGB by name, so a Display-P3 or Adobe RGB source is
///     converted rather than mislabelled — the stored contract is sRGB;
///   * the context is newly allocated and nothing is copied into it but pixels,
///     so no metadata can ride along.
static CGImageRef CreateSRGBBitmap(CGImageRef image, size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (space == NULL) return NULL;
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return NULL;

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat) width, (CGFloat) height), image);
    CGImageRef out = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return out;
}

/// Encode one bitmap as the given media type, with no metadata dictionary.
static NSData *EncodeImage(CGImageRef image, NSString *mediaType, double quality) {
    NSMutableData *output = [NSMutableData data];
    CFStringRef uti = (__bridge CFStringRef) ([mediaType isEqualToString:@"image/png"]
        ? @"public.png" : @"public.jpeg");
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef) output,
                                                                        uti, 1, NULL);
    if (destination == NULL) return nil;
    NSDictionary *properties = [mediaType isEqualToString:@"image/png"]
        ? @{}
        : @{ (__bridge NSString *) kCGImageDestinationLossyCompressionQuality: @(quality / 100.0) };
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef) properties);
    if (!CGImageDestinationFinalize(destination)) {
        CFRelease(destination);
        return nil;
    }
    CFRelease(destination);
    return output;
}

/// Scale one source dimension pair to fit inside a box without enlarging.
///
/// Matches sharp's `resize({ fit: "inside", withoutEnlargement: true })`: the
/// long edge lands exactly on the box when the source is larger, and the short
/// edge is rounded rather than floored, so the aspect ratio stays as close to
/// the source as integer pixels allow.
static void FitInside(long long sourceWidth, long long sourceHeight,
                      long long boxWidth, long long boxHeight,
                      long long *outWidth, long long *outHeight) {
    long long width = sourceWidth;
    long long height = sourceHeight;
    if (boxWidth > 0 && boxHeight > 0) {
        double scale = MIN((double) boxWidth / (double) sourceWidth,
                           (double) boxHeight / (double) sourceHeight);
        if (scale < 1.0) {
            width = MAX(1, (long long) llround((double) sourceWidth * scale));
            height = MAX(1, (long long) llround((double) sourceHeight * scale));
            // Rounding can overshoot the box by one pixel; pull the long edge in.
            if (width > boxWidth) width = boxWidth;
            if (height > boxHeight) height = boxHeight;
        }
    }
    *outWidth = width;
    *outHeight = height;
}

- (NSDictionary<NSString *, id> *)encodeData:(NSData *)data
                                    maxWidth:(long long)maxWidth
                                   maxHeight:(long long)maxHeight
                                    maxBytes:(long long)maxBytes {
    if (data.length == 0) {
        return @{ @"ok": @NO, @"code": ISHImageErrorEmptyInput, @"message": @"Image is empty." };
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef) data, NULL);
    if (source == NULL) {
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Unsupported or malformed image data." };
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    long long sourceWidth = [properties[(__bridge NSString *) kCGImagePropertyPixelWidth] longLongValue];
    long long sourceHeight = [properties[(__bridge NSString *) kCGImagePropertyPixelHeight] longLongValue];
    if (sourceWidth <= 0 || sourceHeight <= 0) {
        CFRelease(source);
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Image header carries no pixel dimensions." };
    }

    long long targetWidth = 0;
    long long targetHeight = 0;
    FitInside(sourceWidth, sourceHeight, maxWidth, maxHeight, &targetWidth, &targetHeight);

    // One decode, at the target size. `kCGImageSourceThumbnailMaxPixelSize` is
    // the long edge, and `WithTransform` bakes the EXIF orientation into the
    // pixels, so nothing downstream has to know about rotation.
    size_t longEdge = (size_t) MAX(targetWidth, targetHeight);
    NSDictionary *options = @{
        (__bridge NSString *) kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *) kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *) kCGImageSourceThumbnailMaxPixelSize: @(longEdge),
        (__bridge NSString *) kCGImageSourceShouldCacheImmediately: @NO,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef) options);
    CFRelease(source);
    if (thumbnail == NULL) {
        return @{ @"ok": @NO, @"code": ISHImageErrorInvalidImage, @"message": @"Unsupported or malformed image data." };
    }

    // The thumbnail API never enlarges a source smaller than the box, but the
    // exact rounding it applies is an implementation detail; re-fit against the
    // bitmap it actually produced so the answer describes real pixels.
    long long actualWidth = (long long) CGImageGetWidth(thumbnail);
    long long actualHeight = (long long) CGImageGetHeight(thumbnail);
    FitInside(actualWidth, actualHeight, maxWidth, maxHeight, &targetWidth, &targetHeight);

    size_t bitmapWidth = (size_t) actualWidth;
    size_t bitmapHeight = (size_t) actualHeight;
    if (targetWidth != actualWidth || targetHeight != actualHeight) {
        bitmapWidth = (size_t) targetWidth;
        bitmapHeight = (size_t) targetHeight;
    }

    CGImageRef bitmap = CreateSRGBBitmap(thumbnail, bitmapWidth, bitmapHeight);
    CGImageRelease(thumbnail);
    if (bitmap == NULL) {
        return @{ @"ok": @NO, @"code": ISHImageErrorEncodeFailed,
                  @"message": @"The image could not be converted to the normalized 8-bit sRGB form." };
    }

    BOOL sourceHasAlpha = [properties[(__bridge NSString *) kCGImagePropertyHasAlpha] boolValue];
    NSString *mediaType = sourceHasAlpha ? @"image/png" : @"image/jpeg";

    NSData *chosen = nil;
    NSData *smallest = nil;
    if (sourceHasAlpha) {
        // PNG is lossless and has one encoding, so the ladder collapses to one
        // attempt. Keeping alpha is the reason this branch exists at all.
        chosen = EncodeImage(bitmap, mediaType, 100.0);
    } else {
        for (size_t index = 0; index < kEncodingQualityCount; index++) {
            NSData *candidate = EncodeImage(bitmap, mediaType, kEncodingQualities[index]);
            if (candidate == nil) continue;
            if (smallest == nil || candidate.length < smallest.length) smallest = candidate;
            if (maxBytes <= 0 || (long long) candidate.length <= maxBytes) {
                chosen = candidate;
                break;
            }
        }
    }
    CGImageRelease(bitmap);

    BOOL oversize = NO;
    if (chosen == nil) {
        // Every ladder step exceeded the byte target. DSH keeps the smallest and
        // lets the route enforce its own cap, so report it rather than failing.
        if (smallest == nil) {
            return @{ @"ok": @NO, @"code": ISHImageErrorEncodeFailed,
                      @"message": @"The image could not be re-encoded as 8-bit sRGB." };
        }
        chosen = smallest;
        oversize = YES;
    }

    // Report the facts of the bytes that were just produced. The provider
    // verifies them, exactly as `verifyNormalizedImage` does for sharp's output;
    // a second round trip to this service would be the same work with more
    // latency, so the probe happens here and travels with the answer.
    NSDictionary *echo = [self probeData:chosen fullDecode:NO maxPixels:0 maxDimension:0];
    return @{
        @"ok": @YES,
        @"data": [chosen base64EncodedStringWithOptions:0],
        @"bytes": @(chosen.length),
        @"mediaType": mediaType,
        @"width": @(bitmapWidth),
        @"height": @(bitmapHeight),
        @"oversize": @(oversize),
        @"depth": echo[@"depth"] ?: @"uchar",
        @"space": echo[@"space"] ?: @"srgb",
        @"hasAlpha": echo[@"hasAlpha"] ?: @(sourceHasAlpha),
        @"animated": echo[@"animated"] ?: @NO,
        @"carriesMetadata": echo[@"carriesMetadata"] ?: @NO,
    };
}

@end
