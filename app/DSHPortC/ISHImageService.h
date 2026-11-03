//
//  ISHImageService.h
//  DSHPortC
//
//  The image decoder DSH needs on a platform that cannot load `sharp`.
//
//  WHY THIS EXISTS: `@deepseek-ai/dsh-attachment-local` does every raster
//  operation through the `sharp` native addon — format sniffing, orientation,
//  alpha and colour-space facts, downscaling, and the JPEG/WebP quality ladder
//  that keeps a model request inside its byte budget. iOS cannot load a
//  third-party addon: `dlopen` of a valid arm64 dylib is refused even when it is
//  ad-hoc signed (REPORT-4B measured both cases), and `sharp` has no iOS
//  prebuild anyway. The bytes still have to be decoded, though, so the decode
//  happens in the platform's own image stack — ImageIO and CoreGraphics — and
//  reaches Node over the same authenticated loopback channel the guest uses.
//
//  WHAT IT GUARANTEES, and why each part is not optional:
//
//    * Header facts before pixels. Every entry point reads the container's
//      properties first and refuses an image whose dimensions exceed the
//      configured limits WITHOUT decoding it. A 100-megapixel HEIC that is
//      decoded first and rejected later is a jetsam kill, not an error message.
//
//    * Downsampling at decode time. Pixels come out through
//      `CGImageSourceCreateThumbnailAtIndex` with a maximum pixel size, so a
//      64-megapixel source never materialises as a 256 MB RGBA buffer on its
//      way to a 2048-pixel target.
//
//    * Orientation applied, metadata dropped. The thumbnail transform bakes the
//      EXIF orientation into the pixels, and re-encoding from a fresh sRGB
//      bitmap context writes no EXIF, GPS, XMP, IPTC or ICC blocks at all. The
//      stored copy therefore carries none of the location data the original
//      did — which is what DSH's normalisation path does too (it re-encodes
//      through a metadata-free sRGB pipeline whenever the source carries any
//      metadata).
//
//    * 8-bit sRGB output only. The normalized form DSH stores and verifies is
//      "single-frame 8-bit sRGB"; drawing into a `kCGImageAlphaPremultipliedLast`
//      sRGB bitmap produces exactly that, including the 16-bit PNG and Display-P3
//      sources that are otherwise not representable.
//
//  It deliberately does NOT implement WebP encoding: ImageIO on iOS decodes
//  WebP but does not encode it, and DSH's own ladder uses WebP only to keep an
//  alpha channel, which PNG preserves losslessly. On the wire this shows up as
//  `image/png` where sharp would have produced `image/webp`; the stored contract
//  ("8-bit sRGB, alpha preserved") is the same.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Failure codes shared with the Node provider, which maps them onto DSH's own
/// `AttachmentError` codes. They are strings rather than an enum so the JSON
/// answer can carry them unchanged.
extern NSString *const ISHImageErrorInvalidImage;        ///< bytes do not decode as a supported raster
extern NSString *const ISHImageErrorTooManyPixels;       ///< width*height over the decode limit
extern NSString *const ISHImageErrorDimensionTooLarge;    ///< one side over the per-side limit
extern NSString *const ISHImageErrorEncodeFailed;         ///< decoded, but could not be re-encoded
extern NSString *const ISHImageErrorEmptyInput;           ///< zero-byte payload

/// One decoded/encoded result, already shaped as the JSON answer the channel sends.
///
/// Every dictionary is JSON-serialisable. A successful answer carries
/// `"ok": @YES`; a failure carries `"ok": @NO`, `"code"` and `"message"`, and
/// never any bytes.
@interface ISHImageService : NSObject

+ (instancetype)shared;

/// Serial queue every decode runs on. Serial rather than concurrent on purpose:
/// two 64-megapixel sources decoding at once is a memory spike this device does
/// not need, and the caller (one model request at a time) gains nothing from it.
@property (nonatomic, readonly) dispatch_queue_t queue;

/// Read container facts, and optionally prove the pixels decode.
///
/// @param data - encoded image bytes (JPEG, PNG, HEIC/HEIF, WebP, GIF, …).
/// @param fullDecode - when YES, also down-sample and render one frame, so a
///   truncated or corrupt payload is refused here instead of at encode time.
///   It never allocates the full-resolution raster.
/// @param maxPixels - refuse before decoding when width*height exceeds this.
///   Zero means no limit.
/// @param maxDimension - refuse before decoding when either side exceeds this.
///   Zero means no limit.
/// @return a JSON-ready dictionary; see the class comment for the shape.
- (NSDictionary<NSString *, id> *)probeData:(NSData *)data
                                 fullDecode:(BOOL)fullDecode
                                  maxPixels:(long long)maxPixels
                               maxDimension:(long long)maxDimension;

/// Decode, orient, convert to 8-bit sRGB, fit inside a box, and re-encode.
///
/// The encoder walks a quality ladder (85, 75, 60) and returns the first JPEG
/// that fits `maxBytes`; when every step exceeds it, the smallest is returned
/// with `"oversize": @YES`, matching sharp's behaviour (the provider still
/// enforces the byte ceiling on the request path). Sources with an alpha channel
/// are encoded as PNG instead, because PNG is the lossless way to keep it and
/// ImageIO has no WebP encoder on iOS.
///
/// The answer includes the facts of the bytes it just produced (`width`,
/// `height`, `depth`, `space`, `hasAlpha`, `animated`, `carriesMetadata`), so
/// the provider can verify the output without a second round trip.
///
/// @param data - encoded source bytes.
/// @param maxWidth - long-edge box width; the result fits inside it, never enlarged.
/// @param maxHeight - long-edge box height.
/// @param maxBytes - byte target for the encoded result.
/// @return a JSON-ready dictionary.
- (NSDictionary<NSString *, id> *)encodeData:(NSData *)data
                                    maxWidth:(long long)maxWidth
                                   maxHeight:(long long)maxHeight
                                    maxBytes:(long long)maxBytes;

/// The media type this service assigns to a container, for diagnostics.
///
/// Exposed so the acceptance run can print what the platform actually called the
/// file instead of inferring it from the extension.
- (nullable NSString *)mediaTypeOfData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
