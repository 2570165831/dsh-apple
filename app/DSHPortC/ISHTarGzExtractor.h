//
//  ISHTarGzExtractor.h
//  DSHPortC
//
//  Unpacks the bundled guest image in process.
//
//  Kept separate from ISHGuest because it has nothing to do with the kernel: it
//  is a tar reader that happens to be used once, at first launch, by the code
//  that installs the rootfs.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISHTarGzExtractor : NSObject

/// Extract `archiveURL` (a .tar.gz) into `destination`, creating it if needed.
///
/// Fails, rather than silently skipping, on any entry type other than a
/// directory or a regular file: the shape of the image is a contract between
/// ish/scripts/build-rootfs.sh and this method, and a link or device node
/// appearing in it means the image was built a different way than intended.
+ (NSError *_Nullable)extractArchiveAtURL:(NSURL *)archiveURL
                            intoDirectory:(NSString *)destination
                                    error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
