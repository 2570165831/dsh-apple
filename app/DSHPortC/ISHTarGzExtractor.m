//
//  ISHTarGzExtractor.m
//  DSHPortC
//
//  Unpacks the bundled guest image.
//
//  Why this exists instead of a `tar -xzf` call: an iOS app cannot start a
//  subprocess — there is no fork/exec, and NSTask is unavailable on the
//  platform, not merely discouraged. So extraction happens in process.
//
//  Why the image is a tar of the fakefs and not of the guest's filesystem:
//  fakefs stores symlink targets and device numbers in meta.db, so the tree on
//  disk is only directories and regular files. A tar of what the *guest* sees
//  would contain 751 symlinks and 8 character devices; an app sandbox can
//  create neither, and a symlink written on the host would not mean what it
//  means in the guest anyway. Unpacking the fakefs is therefore a plain copy.
//
//  The parser is deliberately partial: it handles exactly the entry types this
//  image contains (directories and regular files, GNU long names, pax headers
//  ignored) and fails loudly on anything else rather than guessing. A guest
//  image that grows a symlink or a device node should break the build that
//  produced it, not silently produce a half-populated rootfs on a phone.
//

#import <Foundation/Foundation.h>
#import <zlib.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#import "ISHTarGzExtractor.h"

static const size_t kTarBlock = 512;

#pragma mark - tar header

// A tar header is 512 bytes. The fields below add up to 500; the remaining 12
// bytes are padding, which is exactly why this is NOT declared as a struct and
// memcpy'd wholesale — doing that reads 512 bytes into a 500-byte object and
// trips __memcpy_chk. Fields are located by offset into a raw block instead, so
// the size of the block and the size of the struct cannot disagree.
enum {
    TAR_NAME = 0,      TAR_NAME_LEN = 100,
    TAR_MODE = 100,    TAR_MODE_LEN = 8,
    TAR_UID = 108,     TAR_UID_LEN = 8,
    TAR_GID = 116,     TAR_GID_LEN = 8,
    TAR_SIZE = 124,    TAR_SIZE_LEN = 12,
    TAR_MTIME = 136,   TAR_MTIME_LEN = 12,
    TAR_CHECKSUM = 148, TAR_CHECKSUM_LEN = 8,
    TAR_TYPEFLAG = 156,
    TAR_LINKNAME = 157, TAR_LINKNAME_LEN = 100,
    TAR_MAGIC = 257,   TAR_MAGIC_LEN = 6,
    TAR_VERSION = 263, TAR_VERSION_LEN = 2,
    TAR_UNAME = 265,   TAR_UNAME_LEN = 32,
    TAR_GNAME = 297,   TAR_GNAME_LEN = 32,
    TAR_DEVMAJOR = 329, TAR_DEVMAJOR_LEN = 8,
    TAR_DEVMINOR = 337, TAR_DEVMINOR_LEN = 8,
    TAR_PREFIX = 345,  TAR_PREFIX_LEN = 155,
};

/// Parse a NUL/space-terminated octal field. Returns -1 on anything unexpected.
static long long parse_octal(const char *field, size_t length) {
    long long value = 0;
    size_t i = 0;
    while (i < length && (field[i] == ' ' || field[i] == '\0')) i++;
    if (i == length) return 0;
    for (; i < length; i++) {
        char c = field[i];
        if (c == ' ' || c == '\0') break;
        if (c < '0' || c > '7') return -1;
        value = value * 8 + (c - '0');
    }
    return value;
}

@implementation ISHTarGzExtractor

+ (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:@"dshportc.tar" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Gunzip the whole archive into memory, then walk it.
///
/// Nothing streams: the image is about 13 MB compressed and the largest single
/// member is a few hundred KB, so holding the decompressed tar is cheaper than
/// the complexity of a streaming reader, and it keeps the parser simple enough
/// to audit. If the image ever grows past a sane fraction of device memory this
/// is the thing to change, and it is one function.
+ (NSData *)gunzipData:(NSData *)compressed error:(NSError **)error {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    // 15 + 16 selects gzip framing, which is what tar czf writes on macOS.
    if (inflateInit2(&stream, 15 + 16) != Z_OK) {
        if (error) *error = [self errorWithMessage:@"could not initialise zlib" code:1];
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithCapacity:compressed.length * 4];
    unsigned char buffer[256 * 1024];
    stream.next_in = (Bytef *) compressed.bytes;
    stream.avail_in = (uInt) compressed.length;

    NSData *result = nil;
    for (;;) {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        int status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            if (error) {
                *error = [self errorWithMessage:
                          [NSString stringWithFormat:@"gzip stream failed: %d (%s)",
                                                     status, stream.msg ?: "no detail"]
                                           code:2];
            }
            break;
        }
        size_t produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) [output appendBytes:buffer length:produced];
        if (status == Z_STREAM_END) {
            result = output;
            break;
        }
        if (stream.avail_in == 0 && produced == 0) {
            if (error) *error = [self errorWithMessage:@"gzip stream ended early" code:3];
            break;
        }
    }

    inflateEnd(&stream);
    return result;
}

+ (NSError *)extractArchiveAtURL:(NSURL *)archiveURL
                   intoDirectory:(NSString *)destination
                           error:(NSError **)error {
    NSData *compressed = [NSData dataWithContentsOfURL:archiveURL options:0 error:error];
    if (compressed == nil) {
        if (error && *error == nil) {
            *error = [self errorWithMessage:[NSString stringWithFormat:@"cannot read %@", archiveURL.path]
                                       code:4];
        }
        return *error ?: [self errorWithMessage:@"cannot read the archive" code:4];
    }

    NSError *gunzipError = nil;
    NSData *tar = [self gunzipData:compressed error:&gunzipError];
    if (tar == nil) {
        if (error) *error = gunzipError;
        return gunzipError;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    const unsigned char *bytes = (const unsigned char *) tar.bytes;
    size_t length = tar.length;
    size_t offset = 0;
    NSUInteger fileCount = 0;
    NSUInteger directoryCount = 0;
    NSString *longName = nil;
    NSString *longLink = nil;

    while (offset + kTarBlock <= length) {
        const unsigned char *header = bytes + offset;

        // A zero-filled block ends the archive. The image is written by one tar
        // invocation, so the first block with an empty name is the terminator.
        if (header[TAR_NAME] == '\0') break;

        long long size = parse_octal((const char *) header + TAR_SIZE, TAR_SIZE_LEN);
        if (size < 0) {
            if (error) *error = [self errorWithMessage:@"unparsable size in a tar header" code:5];
            return *error;
        }

        NSMutableString *name = [NSMutableString string];
        if (longName != nil) {
            [name appendString:longName];
            longName = nil;
        } else {
            const char *prefix = (const char *) header + TAR_PREFIX;
            const char *base = (const char *) header + TAR_NAME;
            if (prefix[0] != '\0') {
                [name appendFormat:@"%.*s/", (int) strnlen(prefix, TAR_PREFIX_LEN), prefix];
            }
            [name appendFormat:@"%.*s", (int) strnlen(base, TAR_NAME_LEN), base];
        }

        // Refuse to write outside the destination. The image is ours, so this is
        // defence against a corrupted file rather than against an attacker, but
        // a traversal bug here would scribble over the app container.
        NSString *relative = [name stringByTrimmingCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        NSString *target = [destination stringByAppendingPathComponent:relative];
        NSString *standardDestination = [destination stringByStandardizingPath];
        NSString *standardTarget = [target stringByStandardizingPath];
        if (![standardTarget isEqualToString:standardDestination] &&
            ![standardTarget hasPrefix:[standardDestination stringByAppendingString:@"/"]]) {
            if (error) {
                *error = [self errorWithMessage:
                          [NSString stringWithFormat:@"refusing to extract outside the destination: %@", name]
                                           code:6];
            }
            return *error;
        }

        switch (header[TAR_TYPEFLAG]) {
            case '5': { // directory
                NSError *dirError = nil;
                if (![fm createDirectoryAtPath:standardTarget
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&dirError] && dirError) {
                    if (error) *error = dirError;
                    return dirError;
                }
                directoryCount++;
                break;
            }
            case '0':
            case '\0': { // regular file
                NSString *parent = [standardTarget stringByDeletingLastPathComponent];
                NSError *dirError = nil;
                if (![fm createDirectoryAtPath:parent
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&dirError] && dirError) {
                    if (error) *error = dirError;
                    return dirError;
                }
                if (offset + kTarBlock + (size_t) size > length) {
                    if (error) {
                        *error = [self errorWithMessage:
                                  [NSString stringWithFormat:@"truncated archive at %@", name] code:7];
                    }
                    return *error;
                }
                NSData *contents = [NSData dataWithBytesNoCopy:(void *) (bytes + offset + kTarBlock)
                                                        length:(NSUInteger) size
                                                  freeWhenDone:NO];
                NSError *writeError = nil;
                if (![contents writeToFile:standardTarget options:NSDataWritingAtomic error:&writeError]) {
                    if (error) *error = writeError;
                    return writeError;
                }
                fileCount++;
                break;
            }
            case 'L': { // GNU long name for the next entry
                if (offset + kTarBlock + (size_t) size > length) {
                    if (error) *error = [self errorWithMessage:@"truncated long name" code:8];
                    return *error;
                }
                longName = [[NSString alloc] initWithBytes:bytes + offset + kTarBlock
                                                    length:(NSUInteger) size
                                                  encoding:NSUTF8StringEncoding];
                longName = [longName stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"\0"]];
                break;
            }
            case 'K': { // GNU long link target
                longLink = nil; // links are not extracted; see the header comment
                break;
            }
            case 'x':
            case 'g': { // pax extended headers: metadata only, not applied
                break;
            }
            case '1':
            case '2': { // hard link / symbolic link
                if (error) {
                    *error = [self errorWithMessage:
                              [NSString stringWithFormat:
                                  @"the guest image contains a link (%@); it must contain only "
                                  @"directories and regular files. Rebuild it — see "
                                  @"ish/scripts/build-rootfs.sh.", name]
                                           code:9];
                }
                return *error;
            }
            default: {
                if (error) {
                    *error = [self errorWithMessage:
                              [NSString stringWithFormat:
                                  @"the guest image contains an unsupported tar entry type '%c' (%@)",
                                  header[TAR_TYPEFLAG], name]
                                           code:10];
                }
                return *error;
            }
        }

        // Entries are padded to a 512-byte boundary.
        offset += kTarBlock + (size_t) ((size + kTarBlock - 1) / kTarBlock) * kTarBlock;
    }

    (void) longLink;
    NSLog(@"dshportc: extracted guest image: %lu files, %lu directories",
          (unsigned long) fileCount, (unsigned long) directoryCount);
    if (fileCount == 0) {
        if (error) *error = [self errorWithMessage:@"the guest image contained no files" code:11];
        return *error;
    }
    return nil;
}

@end
