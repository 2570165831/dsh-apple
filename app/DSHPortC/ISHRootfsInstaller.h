//
//  ISHRootfsInstaller.h
//  DSHPortC
//
//  Validates a staged fakefs and preserves the previous guest on replacement.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISHRootfsInstaller : NSObject

/// Called before mount, on the guest queue. Installation never deletes previous roots.
/// The journal recovers an interrupted replacement before trying another import.
+ (NSError *_Nullable)installArchiveAtURL:(NSURL *_Nullable)archiveURL
                                version:(NSString *)version
                                rootURL:(NSURL *)root
                             willImport:(void (^)(void))willImport
                               imported:(BOOL *)imported
                           previousRoot:(NSURL *_Nullable *_Nonnull)previousRoot;

/// Free space an import needs, from the archive's gzip trailer; 0 if unreadable.
+ (unsigned long long)requiredBytesForArchiveAtURL:(NSURL *)archiveURL;

@end

NS_ASSUME_NONNULL_END
