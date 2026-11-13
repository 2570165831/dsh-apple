//
//  ISHRootfsInstaller.m
//  DSHPortC
//

#import "ISHRootfsInstaller.h"
#import "ISHTarGzExtractor.h"

#include <sqlite3.h>
#include <string.h>

@implementation ISHRootfsInstaller

+ (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code cause:(NSError *)cause {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (cause != nil) info[NSUnderlyingErrorKey] = cause;
    return [NSError errorWithDomain:@"dshportc.rootfs" code:code userInfo:info];
}

+ (BOOL)hasFakefsAtURL:(NSURL *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *data = [fm attributesOfItemAtPath:
        [root URLByAppendingPathComponent:@"data"].path error:nil];
    NSDictionary *meta = [fm attributesOfItemAtPath:
        [root URLByAppendingPathComponent:@"meta.db"].path error:nil];
    return [data[NSFileType] isEqualToString:NSFileTypeDirectory]
        && [meta[NSFileType] isEqualToString:NSFileTypeRegular]
        && [meta[NSFileSize] unsignedLongLongValue] > 0;
}

+ (BOOL)checkMetadataAtURL:(NSURL *)root {
    sqlite3 *db = NULL;
    sqlite3_stmt *statement = NULL;
    NSString *path = [root URLByAppendingPathComponent:@"meta.db"].path;
    BOOL valid = NO;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK
        && sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, NULL) == SQLITE_OK
        && sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *answer = sqlite3_column_text(statement, 0);
        valid = answer != NULL && strcmp((const char *)answer, "ok") == 0
            && sqlite3_step(statement) == SQLITE_DONE;
    }
    if (statement != NULL) sqlite3_finalize(statement);
    if (db != NULL) sqlite3_close(db);
    return valid;
}

/// Bytes the import writes: the tar's size from the gzip trailer (ISIZE, the
/// uncompressed length modulo 2^32, which the image is far below) plus room for
/// meta.db growth and the version file. 0 when the trailer cannot be read.
+ (unsigned long long)requiredBytesForArchiveAtURL:(NSURL *)archiveURL {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:archiveURL error:nil];
    if (handle == nil) return 0;
    unsigned long long end = 0;
    NSData *trailer = nil;
    if ([handle seekToEndReturningOffset:&end error:nil] && end >= 18
        && [handle seekToOffset:end - 4 error:nil]) {
        trailer = [handle readDataUpToLength:4 error:nil];
    }
    [handle closeAndReturnError:nil];
    if (trailer.length != 4) return 0;
    const uint8_t *b = trailer.bytes;
    unsigned long long size = (unsigned long long)b[0] | ((unsigned long long)b[1] << 8)
        | ((unsigned long long)b[2] << 16) | ((unsigned long long)b[3] << 24);
    return size + 64ull * 1024 * 1024;
}

+ (NSError *)installArchiveAtURL:(NSURL *)archiveURL
                        version:(NSString *)version
                        rootURL:(NSURL *)root
                     willImport:(void (^)(void))willImport
                       imported:(BOOL *)imported
                   previousRoot:(NSURL **)previousRoot {
    *imported = NO;
    *previousRoot = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *parent = [root URLByDeletingLastPathComponent];
    NSString *prefix = [root.lastPathComponent stringByAppendingString:@".previous-"];
    NSURL *backups = [parent URLByAppendingPathComponent:
        [root.lastPathComponent stringByAppendingString:@"-previous"] isDirectory:YES];
    NSURL *journal = [parent URLByAppendingPathComponent:
        [root.lastPathComponent stringByAppendingString:@".install-backup"]];
    NSError *error = nil;

    // The journal is written before moving the old root and removed after publish.
    if ([fm attributesOfItemAtPath:journal.path error:nil] != nil) {
        NSString *name = [NSString stringWithContentsOfURL:journal encoding:NSUTF8StringEncoding error:&error];
        if (name == nil || ![name hasPrefix:prefix] || ![name.lastPathComponent isEqualToString:name]) {
            return [self errorWithMessage:@"Cannot read the Linux image recovery record; existing data was kept."
                                     code:1 cause:error];
        }
        NSURL *backup = [backups URLByAppendingPathComponent:name isDirectory:YES];
        if ([fm attributesOfItemAtPath:backup.path error:nil] != nil) {
            if ([fm attributesOfItemAtPath:root.path error:nil] == nil) {
                if (![fm moveItemAtURL:backup toURL:root error:&error]) return error;
            } else {
                *previousRoot = backup;
            }
        }
        if (![fm removeItemAtURL:journal error:&error]) return error;
    }

    NSString *installed = [[NSString stringWithContentsOfURL:
        [root URLByAppendingPathComponent:@".installed-version"]
        encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *existing = [fm attributesOfItemAtPath:root.path error:nil];
    if ([existing[NSFileType] isEqualToString:NSFileTypeDirectory] && version.length > 0
        && [installed isEqualToString:version] && [self hasFakefsAtURL:root]
        && [self checkMetadataAtURL:root]) return nil;
    if (version.length == 0 || archiveURL == nil || ![fm isReadableFileAtPath:archiveURL.path]) {
        return [self errorWithMessage:@"ish-rootfs.tar.gz or its version is missing or unreadable; existing guest data was kept."
                                 code:2 cause:nil];
    }

    // Check the volume before touching anything, so a full device keeps its
    // current guest and says how much room the import needs.
    unsigned long long required = [self requiredBytesForArchiveAtURL:archiveURL];
    NSNumber *available = nil;
    if (required > 0
        && [parent getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]
        && available != nil && available.unsignedLongLongValue < required) {
        return [self errorWithMessage:
            [NSString stringWithFormat:@"Not enough free storage to install the Linux image: about %llu MB is needed and %llu MB is available. Free some space and restart the app; existing guest data was kept.",
                                       required / 1000000, available.unsignedLongLongValue / 1000000]
                                 code:8 cause:nil];
    }

    // Only this never-mounted staging tree is disposable after an interrupted import.
    NSURL *staging = [parent URLByAppendingPathComponent:
        [root.lastPathComponent stringByAppendingString:@".installing"] isDirectory:YES];
    if ([fm attributesOfItemAtPath:staging.path error:nil] != nil
        && ![fm removeItemAtURL:staging error:&error]) return error;
    if (![fm createDirectoryAtURL:staging withIntermediateDirectories:YES
                      attributes:nil error:&error]) return error;
    willImport();

    NSURL *backup = nil;
    if (existing != nil) {
        backup = [backups URLByAppendingPathComponent:
            [prefix stringByAppendingString:[[NSUUID UUID] UUIDString]] isDirectory:YES];
        // Exclude the parent, not a guest that may later be restored.
        if (![fm createDirectoryAtURL:backups withIntermediateDirectories:YES
                          attributes:nil error:&error]
            || ![backups setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error]
            || ![backup.lastPathComponent writeToURL:journal atomically:YES
                                           encoding:NSUTF8StringEncoding error:&error]
            || ![fm moveItemAtURL:root toURL:backup error:&error]) {
            [fm removeItemAtURL:staging error:nil];
            return error;
        }
    }

    // Extracted in process: iOS cannot spawn tar (no fork/exec). This is the
    // fakefs tree, containing only regular files and directories NSFileManager
    // can create, not the guest view with symlinks and character devices.
    // See ish/scripts/build-rootfs.sh for why the image has this shape.
    NSError *extractError = [ISHTarGzExtractor extractArchiveAtURL:archiveURL
                                                   intoDirectory:staging.path error:&error];
    if (extractError != nil) error = extractError;
    if (error == nil && (![self hasFakefsAtURL:staging] || ![self checkMetadataAtURL:staging])) {
        error = [self errorWithMessage:@"The imported image is not a complete, readable fakefs."
                                 code:3 cause:nil];
    }
    if (error == nil && ![[version stringByAppendingString:@"\n"]
        writeToURL:[staging URLByAppendingPathComponent:@".installed-version"]
        atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        if (error == nil) error = [self errorWithMessage:@"Could not write the Linux image version."
                                                   code:4 cause:nil];
    }
    if (error == nil && ![fm moveItemAtURL:staging toURL:root error:&error]) {
        if (error == nil) error = [self errorWithMessage:@"Could not publish the Linux image." code:5 cause:nil];
    }
    if (error != nil) {
        [fm removeItemAtURL:staging error:nil];
        if (backup != nil) {
            NSError *restoreError = nil;
            if ([fm attributesOfItemAtPath:root.path error:nil] == nil
                && [fm moveItemAtURL:backup toURL:root error:&restoreError]) {
                [fm removeItemAtURL:journal error:nil];
                return [self errorWithMessage:
                    [NSString stringWithFormat:@"Linux image import failed; the previous guest was restored. Restart the app to retry. %@", error.localizedDescription]
                                         code:6 cause:error];
            }
            // Never overwrite a destination that appeared during import.
            return [self errorWithMessage:
                [NSString stringWithFormat:@"Linux image import failed. Previous data is kept in %@; recovery will be retried on the next launch. %@",
                                           backup.lastPathComponent, error.localizedDescription]
                                     code:7 cause:restoreError ?: error];
        }
        return error;
    }

    *imported = YES;
    if (backup != nil) *previousRoot = backup;
    [fm removeItemAtURL:journal error:nil];
    return nil;
}

@end
