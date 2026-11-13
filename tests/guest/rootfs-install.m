// Host-side installer checks with a fault-injected extractor; no guest kernel needed.

#import "ISHRootfsInstaller.h"
#import "ISHTarGzExtractor.h"
#include <sqlite3.h>

static NSString *mode;
static NSUInteger extractions;
static NSUInteger imports;

static void writeText(NSString *text, NSString *path) {
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    NSCAssert(ok, @"write failed: %@", error);
}

static NSString *readText(NSURL *root, NSString *path) {
    return [NSString stringWithContentsOfFile:[root.path stringByAppendingPathComponent:path]
                                    encoding:NSUTF8StringEncoding error:nil];
}

static void mkdirAt(NSString *path) {
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:&error];
    NSCAssert(ok, @"mkdir failed: %@", error);
}

static void fakefs(NSURL *root, NSString *version) {
    mkdirAt([root.path stringByAppendingPathComponent:@"data"]);
    writeText(@"user file", [root.path stringByAppendingPathComponent:@"data/sentinel"]);
    if (version != nil) writeText(version, [root.path stringByAppendingPathComponent:@".installed-version"]);
    sqlite3 *db = NULL;
    NSString *meta = [root.path stringByAppendingPathComponent:@"meta.db"];
    NSCAssert(sqlite3_open(meta.fileSystemRepresentation, &db) == SQLITE_OK, @"open metadata");
    NSCAssert(sqlite3_exec(db, "CREATE TABLE files (id INTEGER)", NULL, NULL, NULL) == SQLITE_OK,
              @"create metadata");
    sqlite3_close(db);
}

static NSURL *backupsFor(NSURL *root) {
    return [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"ish-root-previous" isDirectory:YES];
}

static NSError *install(NSURL *archive, NSString *version, NSURL *root, BOOL *imported, NSURL **previous) {
    return [ISHRootfsInstaller installArchiveAtURL:archive version:version rootURL:root
        willImport:^{ imports++; } imported:imported previousRoot:previous];
}

@implementation ISHTarGzExtractor
+ (NSError *)extractArchiveAtURL:(NSURL *)archiveURL
                   intoDirectory:(NSString *)destination
                           error:(NSError **)error {
    extractions++;
    (void)archiveURL;
    fakefs([NSURL fileURLWithPath:destination], nil);
    if ([mode isEqualToString:@"failure"]) {
        *error = [NSError errorWithDomain:@"test.extract" code:1 userInfo:nil];
        return *error;
    }
    if ([mode isEqualToString:@"returned-error"]) {
        return [NSError errorWithDomain:@"test.extract" code:2 userInfo:nil];
    }
    NSString *meta = [destination stringByAppendingPathComponent:@"meta.db"];
    if ([mode isEqualToString:@"missing-meta"]) [[NSFileManager defaultManager] removeItemAtPath:meta error:nil];
    if ([mode isEqualToString:@"corrupt-meta"]) writeText(@"not sqlite", meta);
    if ([mode isEqualToString:@"stamp-failure"]) mkdirAt([destination stringByAppendingPathComponent:@".installed-version"]);
    if ([mode isEqualToString:@"collision"]) {
        NSString *root = [destination stringByDeletingPathExtension];
        mkdirAt(root);
        writeText(@"late destination", [root stringByAppendingPathComponent:@"sentinel"]);
    }
    return nil;
}
@end

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] isDirectory:YES];
        mkdirAt(scratch.path);
        @try {
            NSURL *archive = [scratch URLByAppendingPathComponent:@"image.tar.gz"];
            writeText(@"fixture", archive.path);
            NSURL *(^rootFor)(NSString *) = ^NSURL *(NSString *name) {
                NSURL *parent = [scratch URLByAppendingPathComponent:name isDirectory:YES];
                mkdirAt(parent.path);
                return [parent URLByAppendingPathComponent:@"ish-root" isDirectory:YES];
            };
            BOOL imported = NO;
            NSURL *previous = nil;
            mode = @"valid";
            NSURL *root = rootFor(@"fresh");
            NSError *error = install(archive, @"v1", root, &imported, &previous);
            NSCAssert(error == nil && imported && previous == nil, @"fresh import: %@", error);
            NSCAssert([readText(root, @".installed-version") isEqualToString:@"v1\n"], @"stamp");
            NSCAssert(![fm fileExistsAtPath:[root.path stringByAppendingString:@".installing"]], @"stage published");
            NSUInteger count = extractions, phases = imports;
            error = install(nil, @"v1", root, &imported, &previous);
            NSCAssert(error == nil && !imported && extractions == count && imports == phases,
                      @"reuse must not extract or report importing");

            error = install(nil, @"v2", root, &imported, &previous);
            NSCAssert(error != nil && !imported && extractions == count, @"missing archive must keep old root");
            NSCAssert([readText(root, @".installed-version") isEqualToString:@"v1\n"], @"old stamp kept");

            error = install(archive, @"v2", root, &imported, &previous);
            NSCAssert(error == nil && imported && previous != nil, @"upgrade: %@", error);
            NSCAssert([readText(previous, @"data/sentinel") isEqualToString:@"user file"], @"old data kept");
            NSCAssert([readText(previous, @".installed-version") isEqualToString:@"v1\n"], @"old version kept");
            NSCAssert([previous.URLByDeletingLastPathComponent.path isEqualToString:backupsFor(root).path],
                      @"backups share a resettable parent");
            NSNumber *excluded = nil;
            NSCAssert([backupsFor(root) getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil]
                && excluded.boolValue, @"old guests excluded from device backup");
            NSURL *firstBackup = previous;
            error = install(archive, @"v3", root, &imported, &previous);
            NSCAssert(error == nil && imported && ![previous isEqual:firstBackup], @"unique backup per upgrade");
            NSCAssert([readText(firstBackup, @".installed-version") isEqualToString:@"v1\n"], @"earlier backup kept");

            NSURL *blocked = rootFor(@"blocked-backups");
            fakefs(blocked, @"v1");
            writeText(@"keep obstacle", backupsFor(blocked).path);
            count = extractions;
            error = install(archive, @"v2", blocked, &imported, &previous);
            NSCAssert(error != nil && !imported && extractions == count, @"backup preparation must fail before extraction");
            NSCAssert([readText(blocked, @"data/sentinel") isEqualToString:@"user file"]
                && [readText(blocked, @".installed-version") isEqualToString:@"v1"], @"backup failure keeps old guest");
            NSCAssert(![fm fileExistsAtPath:[blocked.path stringByAppendingString:@".install-backup"]],
                      @"backup failure leaves no recovery record");

            for (NSString *kind in @[@"missing-data", @"missing-meta", @"missing-stamp", @"corrupt-meta"]) {
                NSURL *broken = rootFor(kind);
                fakefs(broken, [kind isEqualToString:@"missing-stamp"] ? nil : @"v1");
                writeText(@"keep incomplete", [broken.path stringByAppendingPathComponent:@"sentinel"]);
                if ([kind isEqualToString:@"missing-data"]) [fm removeItemAtURL:[broken URLByAppendingPathComponent:@"data"] error:nil];
                if ([kind isEqualToString:@"missing-meta"]) [fm removeItemAtURL:[broken URLByAppendingPathComponent:@"meta.db"] error:nil];
                if ([kind isEqualToString:@"corrupt-meta"]) writeText(@"broken", [broken.path stringByAppendingPathComponent:@"meta.db"]);
                error = install(archive, @"v1", broken, &imported, &previous);
                NSCAssert(error == nil && imported, @"%@ must recover: %@", kind, error);
                NSCAssert([readText(previous, @"sentinel") isEqualToString:@"keep incomplete"], @"incomplete data kept");
            }

            for (NSString *failure in @[@"failure", @"returned-error", @"missing-meta", @"corrupt-meta", @"stamp-failure"]) {
                mode = failure;
                NSURL *old = rootFor([@"old-" stringByAppendingString:failure]);
                fakefs(old, @"v1\n");
                error = install(archive, @"v2", old, &imported, &previous);
                NSCAssert(error != nil && !imported, @"%@ must fail", failure);
                NSCAssert([readText(old, @"data/sentinel") isEqualToString:@"user file"]
                    && [readText(old, @".installed-version") isEqualToString:@"v1\n"], @"%@ must restore old data", failure);
                NSURL *fresh = rootFor([@"new-" stringByAppendingString:failure]);
                error = install(archive, @"v1", fresh, &imported, &previous);
                NSCAssert(error != nil && !imported && ![fm fileExistsAtPath:fresh.path],
                          @"%@ must not publish a partial root", failure);
            }

            root = rootFor(@"interrupted-missing-archive");
            NSURL *saved = [backupsFor(root) URLByAppendingPathComponent:@"ish-root.previous-saved"];
            fakefs(saved, @"v1");
            writeText(saved.lastPathComponent, [root.path stringByAppendingString:@".install-backup"]);
            error = install(nil, @"v2", root, &imported, &previous);
            NSCAssert(error != nil && !imported
                && [readText(root, @".installed-version") isEqualToString:@"v1"],
                @"recovery must restore old data even without an archive");

            root = rootFor(@"invalid-journal");
            fakefs(root, @"v1");
            writeText(@"../outside", [root.path stringByAppendingString:@".install-backup"]);
            error = install(archive, @"v2", root, &imported, &previous);
            NSCAssert(error != nil && !imported
                && [readText(root, @"data/sentinel") isEqualToString:@"user file"], @"invalid journal must keep data");

            mode = @"valid";
            root = rootFor(@"interrupted-import");
            NSURL *backup = [backupsFor(root) URLByAppendingPathComponent:@"ish-root.previous-interrupted"];
            fakefs(backup, @"v1");
            writeText(backup.lastPathComponent, [root.path stringByAppendingString:@".install-backup"]);
            mkdirAt([root.path stringByAppendingString:@".installing"]);
            writeText(@"partial", [[root.path stringByAppendingString:@".installing"] stringByAppendingPathComponent:@"partial"]);
            error = install(archive, @"v2", root, &imported, &previous);
            NSCAssert(error == nil && imported, @"interrupted replacement retries: %@", error);
            NSCAssert([readText(previous, @"data/sentinel") isEqualToString:@"user file"], @"interrupted old root kept");
            NSCAssert(![fm fileExistsAtPath:[root.path stringByAppendingPathComponent:@"partial"]], @"stale stage cleared");

            root = rootFor(@"interrupted-publish");
            fakefs(root, @"v2");
            backup = [backupsFor(root) URLByAppendingPathComponent:@"ish-root.previous-published"];
            fakefs(backup, @"v1");
            writeText(backup.lastPathComponent, [root.path stringByAppendingString:@".install-backup"]);
            count = extractions;
            error = install(nil, @"v2", root, &imported, &previous);
            NSCAssert(error == nil && !imported && extractions == count
                && [previous.path isEqualToString:backup.path], @"published image reused and backup reported");

            root = rootFor(@"interrupted-before-rename");
            fakefs(root, @"v1");
            writeText(@"ish-root.previous-not-moved", [root.path stringByAppendingString:@".install-backup"]);
            error = install(nil, @"v1", root, &imported, &previous);
            NSCAssert(error == nil && !imported && previous == nil, @"journal before rename is harmless");

            root = rootFor(@"missing-bundle");
            error = install(nil, @"v1", root, &imported, &previous);
            NSCAssert(error != nil && !imported && ![fm fileExistsAtPath:root.path], @"missing bundle");

            mode = @"collision";
            root = rootFor(@"collision");
            fakefs(root, @"v1");
            error = install(archive, @"v2", root, &imported, &previous);
            NSCAssert(error != nil && !imported, @"late destination must not be overwritten");
            NSCAssert([readText(root, @"sentinel") isEqualToString:@"late destination"], @"late root kept");
            NSString *name = [NSString stringWithContentsOfFile:[root.path stringByAppendingString:@".install-backup"]
                                                      encoding:NSUTF8StringEncoding error:nil];
            backup = [backupsFor(root) URLByAppendingPathComponent:name];
            NSCAssert([readText(backup, @"data/sentinel") isEqualToString:@"user file"], @"collision keeps old backup");

            NSURL *sized = [scratch URLByAppendingPathComponent:@"sized.tar.gz"];
            uint8_t bytes[20] = {0x1f, 0x8b};
            bytes[16] = 0x10; bytes[17] = 0x27;  // ISIZE = 10000, little endian
            [[NSData dataWithBytes:bytes length:sizeof bytes] writeToURL:sized atomically:YES];
            NSCAssert([ISHRootfsInstaller requiredBytesForArchiveAtURL:sized] == 10000 + 64ull * 1024 * 1024,
                      @"space needed comes from the gzip trailer");
            NSCAssert([ISHRootfsInstaller requiredBytesForArchiveAtURL:archive] == 0,
                      @"a file too short for a trailer skips the check");

            NSLog(@"rootfs installer checks passed");
        } @finally {
            [fm removeItemAtURL:scratch error:nil];
        }
    }
    return 0;
}
