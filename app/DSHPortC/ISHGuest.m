//
//  ISHGuest.m
//  DSHPortC
//
//  Boots the iSH ARM64 kernel inside the app and runs commands through it.
//
//  This file is the answer to one question: what does an app have to do before
//  it may call into this kernel, and what has to be replaced so the kernel
//  cannot take the app down with it. The boot order follows
//  deepseek-harness-ios's Docs/ISH_SANDBOX_PORT.md, which in turn follows
//  ish-arm64's own AppDelegate. Deviating from that order produces failures
//  that look unrelated to the change that caused them.
//
//  Three "slots" are global function pointers in the kernel and MUST be
//  replaced before the guest runs. They are why this file exists at all:
//
//  1. die_handler. kernel/log.c's die() calls die_handler(buf) and then
//     abort() unconditionally. A handler that returns therefore kills the app.
//     The replacement must not return — this one parks the calling thread
//     forever and records the message.
//  2. exit_hook. kernel/exit.c calls it on the exiting task's thread; the app
//     needs to know a command finished.
//  3. The console tty driver. Without one, /dev/console opens fail and
//     create_stdio falls back to adhoc fds with no reader behind them.
//
//  Everything here runs on a single serial queue. The kernel is not
//  thread-safe from the host side: `current` is thread-local, so the host
//  thread that calls do_execve becomes the guest process, and interleaving two
//  such calls produces two "current" tasks that both think they are init.
//

#import "ISHGuest.h"
#import "ISHTarGzExtractor.h"

#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

// The kernel headers gate themselves on ISH_INTERNAL, which is the fork's way of
// saying "these are not a stable API, you are inside the tree now". Setting it
// here is the whole of what embedding requires; it is set for the app target in
// the project file so it also applies to any file added later.
#ifndef ISH_INTERNAL
#define ISH_INTERNAL 1
#endif

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "kernel/mm.h"
#include "kernel/errno.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/dev.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "emu/cpu.h"

// The kernel's own reference to the console tty, so the replacement driver can
// tell "this is the console" from "this is some other console".
extern int console_major;
extern int console_minor;

// Defined in the kernel; the hooks below replace them.
extern void (*die_handler)(const char *msg);
extern void (*exit_hook)(struct task *task, int code);

#pragma mark - Guest log

@implementation ISHGuestLog {
    NSMutableArray<NSString *> *_lines;
    dispatch_queue_t _queue;
}

+ (ISHGuestLog *)shared {
    static ISHGuestLog *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ISHGuestLog alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _lines = [NSMutableArray array];
        _queue = dispatch_queue_create("local.dshportc.guestlog", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// Bounded on purpose: a command that prints for ten minutes must not turn into
// an out-of-memory kill of an app that is otherwise fine.
static const NSUInteger kMaxLogLines = 4000;

- (void)append:(NSString *)line {
    if (line == nil) return;
    dispatch_async(_queue, ^{
        [self->_lines addObject:line];
        if (self->_lines.count > kMaxLogLines) {
            [self->_lines removeObjectsInRange:NSMakeRange(0, self->_lines.count - kMaxLogLines)];
        }
    });
}

- (NSArray<NSString *> *)lines {
    __block NSArray<NSString *> *copy;
    dispatch_sync(_queue, ^{ copy = [self->_lines copy]; });
    return copy;
}

- (NSString *)text {
    return [[self lines] componentsJoinedByString:@"\n"];
}

- (void)clear {
    dispatch_async(_queue, ^{ [self->_lines removeAllObjects]; });
}

@end

#pragma mark - die handler

// Observed by the die-test helper (ISHGuestDieTest.m), so a test can confirm the
// handler actually ran rather than merely noticing the app survived.
volatile int dsh_die_handler_call_count = 0;
char dsh_die_handler_last_message[1024];

// MUST NOT RETURN. kernel/log.c's die() calls this and then abort()s; returning
// here is the exact bug the plan warns about. Parking the thread is safe because
// the thread belongs to the guest task that faulted — it is expendable, and the
// rest of the app (including the console reporting what happened) keeps running.
static void dsh_die_handler(const char *msg) {
    __atomic_add_fetch(&dsh_die_handler_call_count, 1, __ATOMIC_SEQ_CST);
    strlcpy(dsh_die_handler_last_message, msg ?: "(null)",
            sizeof(dsh_die_handler_last_message));

    char buf[1200];
    int len = snprintf(buf, sizeof(buf), "=== guest kernel die(): %s ===\n", msg ?: "(null)");
    if (len > 0) write(STDERR_FILENO, buf, (size_t) len);

    NSString *text = [NSString stringWithFormat:@"guest kernel die(): %s", msg ?: "(null)"];
    NSLog(@"dshportc: %@", text);
    [[ISHGuestLog shared] append:text];

    // Block every signal on this thread, then sleep forever. pthread_exit is
    // not used: on this platform it can raise SIGTRAP in some thread states,
    // and a crash there would defeat the point of surviving a die().
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    for (;;) {
        select(0, NULL, NULL, NULL, NULL);
    }
}

#pragma mark - exit hook

// Written by the exit hook (on the exiting guest thread), read by the serial
// queue that waits for it. A single in-flight command means one slot is enough.
static int g_exitedPID = 0;
static int g_exitedStatus = 0;
static int g_exitPending = 0;

// Per-process exit slots, for the streaming channel.
//
// The three globals above are enough for the debug console because it runs one
// command at a time on the guest queue and cannot have two exits racing. The
// channel starts its command on the guest queue but drains the pipes on another
// thread, so a second exec could in principle begin before the first has been
// reaped; a single slot would then report the wrong status to one of them.
//
// The table is fixed-size and lock-free on the guest side: the hook runs with
// pids_lock held and may not call anything that could block. Registration
// happens BEFORE task_start (see execRequest:), so a command that exits
// immediately still finds its slot.
#define DSH_MAX_EXEC_SLOTS 16

// Plain `int` fields rather than `_Atomic int`: the GCC `__atomic_*` builtins
// this file already uses take an address to an *integer*, and reject a pointer
// to an `_Atomic(int)`. The builtins are what provide the atomicity, so the
// qualifier is redundant as well as being a compile error here.
struct dsh_exit_slot {
    int pid;      // 0 = free
    int status;   // raw wait status
    int pending;  // 1 once the hook has written status
    int claimed;  // 1 once a reader has taken the status
};

static struct dsh_exit_slot g_exitSlots[DSH_MAX_EXEC_SLOTS];

static struct dsh_exit_slot *dsh_exit_slot_for_pid(int pid) {
    if (pid <= 0) return NULL;
    for (int i = 0; i < DSH_MAX_EXEC_SLOTS; i++) {
        if (__atomic_load_n(&g_exitSlots[i].pid, __ATOMIC_SEQ_CST) == pid)
            return &g_exitSlots[i];
    }
    return NULL;
}

/// Reserve a slot for `pid`. Called before task_start, from the guest queue.
static int dsh_exit_slot_register(int pid) {
    for (int i = 0; i < DSH_MAX_EXEC_SLOTS; i++) {
        int expected = 0;
        if (__atomic_compare_exchange_n(&g_exitSlots[i].pid, &expected, pid,
                                        false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
            __atomic_store_n(&g_exitSlots[i].status, 0, __ATOMIC_SEQ_CST);
            __atomic_store_n(&g_exitSlots[i].pending, 0, __ATOMIC_SEQ_CST);
            __atomic_store_n(&g_exitSlots[i].claimed, 0, __ATOMIC_SEQ_CST);
            return i;
        }
    }
    return -1;
}

static void dsh_exit_slot_release(int index) {
    if (index < 0 || index >= DSH_MAX_EXEC_SLOTS) return;
    __atomic_store_n(&g_exitSlots[index].pending, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitSlots[index].status, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitSlots[index].claimed, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitSlots[index].pid, 0, __ATOMIC_SEQ_CST);
}

static void dsh_exit_hook(struct task *task, int code) {
    // Only report the process the app started, and only its descendants' leader.
    // The kernel calls this with pids_lock held; keep it to atomics and a
    // dispatch_async, both of which are safe there.
    if (task == NULL) return;
    int pid = task->pid;
    __atomic_store_n(&g_exitedPID, pid, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitedStatus, code, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitPending, 1, __ATOMIC_SEQ_CST);
    struct dsh_exit_slot *slot = dsh_exit_slot_for_pid(pid);
    if (slot != NULL) {
        __atomic_store_n(&slot->status, code, __ATOMIC_SEQ_CST);
        __atomic_store_n(&slot->pending, 1, __ATOMIC_SEQ_CST);
    }
}

#pragma mark - console tty driver

// The console driver writes guest output straight to the app. There is no
// terminal emulator behind it in this build: the guest's stdout goes into a
// ring buffer the console view reads, and stdin is not connected. That is
// honest for a debug path — an interactive shell needs the PTY work that
// belongs with the Node channel, not here.
static dispatch_queue_t _consoleQueue;

static int dsh_tty_init(struct tty *tty) {
    tty->winsize.col = 100;
    tty->winsize.row = 40;
    return 0;
}

static int dsh_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    if (len == 0) return 0;
    NSData *data = [NSData dataWithBytes:buf length:len];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (text != nil) {
        [[ISHGuestLog shared] append:text];
    }
    return (int) len;
}

static void dsh_tty_cleanup(struct tty *tty) {
    (void) tty;
}

static struct tty_driver_ops dsh_tty_ops = {
    .init = dsh_tty_init,
    .write = dsh_tty_write,
    .cleanup = dsh_tty_cleanup,
};
DEFINE_TTY_DRIVER(dsh_console_driver, &dsh_tty_ops, TTY_CONSOLE_MAJOR, 64);

#pragma mark - rootfs install

// The bundled image is a tar of the fakefs (data/ + meta.db), produced by
// ish/scripts/build-rootfs.sh with unfakefsify. It is imported once, into
// Application Support, and never re-imported unless the version file says so.
static NSString *const kRootfsVersionKey = @"ish.rootfs.version";

#pragma mark - ISHGuestExecRequest

@implementation ISHGuestExecRequest
- (instancetype)init {
    if (self = [super init]) {
        _timeout = 0;
        _maxOutputBytes = 0;
        // The debug console's caller wants a copy. The Node channel turns this
        // off explicitly; see the header for why bounded output belongs there.
        _retainOutput = YES;
    }
    return self;
}
@end

@implementation ISHGuestExecResult
@end

// Forward declarations for the streaming path. Each is defined further down
// next to its only caller; keeping the order explicit here is what lets
// `-Werror=implicit-function-declaration` catch a rename.
NSString *dsh_errno_name(int err);
int sys_chdir_guest(const char *path);

// The guest-side output cap for one exec.
//
// `maxOutputBytes` is not the same question as "truncate what the model sees":
// the Node side owns maxBytes/spill (step 5). This cap only exists so a `yes`
// in the guest cannot grow an NSMutableData until the app is killed; the count
// of what was dropped is reported so the Node side can tell the model the
// output was cut.
static const NSUInteger kDefaultExecMaxOutputBytes = 8u * 1024 * 1024;

/// How long a terminated command gets between SIGTERM and SIGKILL.
///
/// 200 ms matches the deepseek-harness-ios number and is chosen for the same
/// reason: a guest shell needs long enough to notice SIGTERM and reap the jobs
/// it started itself, but the caller is already waiting on a teardown, so
/// anything longer just delays the model's next step.
static const NSTimeInterval kTerminationGraceSeconds = 0.2;

/// After SIGKILL, how long to keep reading pipes whose writer has not gone away.
static const NSTimeInterval kAbandonPipesAfterSeconds = 2.0;

/// Children of `pid` currently in the guest, walked through `task->children`
/// with `pids_lock` held by the caller.
///
/// A fixed-size collector rather than a growing array: this runs while the
/// kernel's global PID lock is held (the exit hook's constraint), where an
/// allocation could deadlock against the allocator.
#define DSH_MAX_TREE_PIDS 256

/// Collect `root` and every guest descendant of it. Returns the count.
static int dsh_collect_process_tree(int root, int *out, int cap) {
    if (root <= 0 || cap <= 0) return 0;
    int count = 0;
    int queue[DSH_MAX_TREE_PIDS];
    int head = 0, tail = 0;
    queue[tail++] = root;
    while (head < tail && count < cap) {
        int pid = queue[head++];
        // PID 1 is the guest's init and owns the whole namespace. Signalling it
        // would take the guest down with no way back, so it is never in the set.
        if (pid == 1) continue;
        BOOL seen = NO;
        for (int i = 0; i < count; i++) {
            if (out[i] == pid) { seen = YES; break; }
        }
        if (seen) continue;
        out[count++] = pid;
        struct task *task = pid_get_task((dword_t) pid);
        if (task == NULL) continue;
        struct task *child;
        list_for_each_entry(&task->children, child, siblings) {
            if (tail < DSH_MAX_TREE_PIDS && child->pid > 0) queue[tail++] = (int) child->pid;
        }
    }
    return count;
}

/// Everything one streaming exec needs to keep between start, drain and finish.
///
/// Declared here, before `@implementation ISHGuest`, because an `@interface`
/// may not appear inside an `@implementation`: the compiler reads the file as a
/// sequence of top-level declarations.
@interface DSHGuestRun : NSObject
@property (nonatomic) int stdoutRead;
@property (nonatomic) int stderrRead;
@property (nonatomic) int stdinWrite;
@property (nonatomic) int guestPID;
@property (nonatomic) int exitSlot;
@property (nonatomic, copy) NSString *execID;
@property (nonatomic) NSTimeInterval started;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic) NSUInteger maxBytes;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL timedOut;
/// Whether this side keeps a copy of the output. NO for the Node channel: it
/// counts bytes and lets them stream past, because the Node-side collector owns
/// the cap and the complete-stream spill promise.
@property (nonatomic) BOOL retainOutput;
/// Set once the caller asked for termination, so the drain thread runs the
/// SIGTERM → grace → SIGKILL ladder exactly once instead of hammering SIGKILL
/// every poll (which is what the previous `if (run.cancelled)` did).
@property (nonatomic) BOOL terminationStarted;
/// When the termination ladder started, for the grace window.
@property (nonatomic) NSTimeInterval terminationStartedAt;
/// Last SIGKILL escalation attempt, so escalation is throttled per run rather
/// than once per drain poll or once per process lifetime.
@property (nonatomic) NSTimeInterval lastEscalationAt;
/// The whole stdin the caller handed us, written to the child from the drain
/// thread. Empty means "write nothing, close the pipe" — which gives the child
/// a real EOF, so `cat > f` and a heredoc both terminate instead of hanging.
@property (nonatomic, strong) NSData *stdinData;
/// How much of `stdinData` has been written already.
@property (nonatomic) NSUInteger stdinWritten;
/// Set once the write end is closed (all stdin written, or the child stopped
/// reading). Closing it is what delivers EOF.
@property (nonatomic) BOOL stdinClosed;
@property (nonatomic, strong) NSMutableData *stdoutData;
@property (nonatomic, strong) NSMutableData *stderrData;
@property (nonatomic) unsigned long long totalBytes;
@property (nonatomic) BOOL truncated;
/// Immutable copies of the blocks the caller gave us.
@property (nonatomic, strong) id chunkBlock;
@property (nonatomic, strong) id lineBlock;
@end


@implementation DSHGuestRun
- (instancetype)init {
    if (self = [super init]) {
        _stdoutRead = -1;
        _stderrRead = -1;
        _stdinWrite = -1;
        _exitSlot = -1;
        _maxBytes = kDefaultExecMaxOutputBytes;
        _retainOutput = YES;
        _stdinClosed = NO;
        _stdoutData = [NSMutableData data];
        _stderrData = [NSMutableData data];
    }
    return self;
}
@end

#pragma mark - ISHGuest

@implementation ISHGuestResult
@end

@implementation ISHGuest {
    dispatch_queue_t _guestQueue;
    BOOL _booted;
    NSTimeInterval _bootSeconds;
    NSTimeInterval _rootfsImportSeconds;
    NSString *_rootPath;

    // The one command in flight, if any.
    BOOL _commandRunning;
    int _commandPID;
    NSMutableString *_stdoutBuffer;
    NSMutableString *_stderrBuffer;
    NSUInteger _stdoutRetained;
    NSUInteger _stderrRetained;
    ISHGuestLineBlock _lineBlock;
    NSUInteger _stdoutLineStart;
    NSUInteger _stderrLineStart;

    // Workspace mapping, once bindMountGuestPath: has succeeded.
    NSString *_boundWorkspaceGuestPath;
    NSString *_boundWorkspaceHostPath;
}

+ (ISHGuest *)shared {
    static ISHGuest *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ISHGuest alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _guestQueue = dispatch_queue_create("local.dshportc.guest", DISPATCH_QUEUE_SERIAL);
        _state = ISHGuestStateIdle;
        _stateDetail = @"not started";
        _consoleQueue = dispatch_queue_create("local.dshportc.console", DISPATCH_QUEUE_SERIAL);
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
    }
    return self;
}

- (void)setState:(ISHGuestState)state detail:(NSString *)detail {
    _state = state;
    _stateDetail = [detail copy];
    NSLog(@"dshportc: guest %ld %@", (long) state, detail);
    [[ISHGuestLog shared] append:[NSString stringWithFormat:@"[guest] %@", detail]];
}

- (NSString *)rootPath { return _rootPath; }
- (double)bootSeconds { return _bootSeconds; }
- (double)rootfsImportSeconds { return _rootfsImportSeconds; }
- (NSString *)boundWorkspaceGuestPath { return _boundWorkspaceGuestPath; }
- (NSString *)boundWorkspaceHostPath { return _boundWorkspaceHostPath; }

#pragma mark container paths

- (NSURL *)applicationSupport {
    NSURL *url = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask] firstObject];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:url
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    }
    return [url URLByResolvingSymlinksInPath];
}

- (NSURL *)rootURL {
    return [[self applicationSupport] URLByAppendingPathComponent:@"ish-root" isDirectory:YES];
}

/// Import the bundled rootfs if there is not a current one already.
- (NSError *)ensureRootfsInstalled {
    NSString *bundledVersion = [self bundledRootfsVersion];
    if (bundledVersion == nil) {
        return [NSError errorWithDomain:@"dshportc.guest" code:1
                               userInfo:@{NSLocalizedDescriptionKey:
                                              @"the app bundle has no ish-rootfs.tar.gz; build it with ish/scripts/build-rootfs.sh"}];
    }

    NSURL *root = [self rootURL];
    NSString *versionPath = [[root URLByAppendingPathComponent:@".installed-version"] path];
    // Trimmed like the bundled version: the file is written with a newline, and an
    // untrimmed compare re-imported the rootfs on every launch, wiping the guest.
    NSString *installed = [[NSString stringWithContentsOfFile:versionPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL complete = [[NSFileManager defaultManager] fileExistsAtPath:
                        [[root URLByAppendingPathComponent:@"data"] path]]
                 && [[NSFileManager defaultManager] fileExistsAtPath:
                        [[root URLByAppendingPathComponent:@"meta.db"] path]];

    if (complete && [installed isEqualToString:bundledVersion]) {
        [self setState:ISHGuestStateMounting detail:@"rootfs already installed"];
        _rootPath = [root path];
        return nil;
    }

    [self setState:ISHGuestStateInstallingRoot
            detail:[NSString stringWithFormat:@"importing rootfs %@", bundledVersion]];
    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];

    [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:root
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&error];
    if (error) return error;

    NSURL *archive = [[NSBundle mainBundle] URLForResource:@"ish-rootfs" withExtension:@"tar.gz"];
    if (archive == nil) {
        return [NSError errorWithDomain:@"dshportc.guest" code:2
                               userInfo:@{NSLocalizedDescriptionKey:
                                              @"ish-rootfs.tar.gz is not in the app bundle"}];
    }

    // Extracted in process. An iOS app cannot spawn tar (no fork/exec), and the
    // archive is the fakefs tree rather than the guest's own filesystem, so it
    // is only regular files and directories -- exactly what NSFileManager can
    // create. See ish/scripts/build-rootfs.sh for why the image is shaped this
    // way: the alternative, a tar of the guest view, contains symlinks and
    // character devices the sandbox will not let anyone create.
    NSError *extractError = nil;
    [ISHTarGzExtractor extractArchiveAtURL:archive intoDirectory:root.path error:&extractError];
    if (extractError) return extractError;

    NSString *versionContents = [NSString stringWithFormat:@"%@\n", bundledVersion];
    [versionContents writeToFile:versionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    _rootfsImportSeconds = [NSDate timeIntervalSinceReferenceDate] - started;
    [self setState:ISHGuestStateMounting
            detail:[NSString stringWithFormat:@"rootfs imported in %.2f s",
                                              _rootfsImportSeconds]];
    _rootPath = [root path];
    return nil;
}

- (NSString *)bundledRootfsVersion {
    NSURL *path = [[NSBundle mainBundle] URLForResource:@"ish-rootfs" withExtension:@"version"];
    if (path != nil) {
        return [[NSString stringWithContentsOfURL:path encoding:NSUTF8StringEncoding error:nil]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSURL *archive = [[NSBundle mainBundle] URLForResource:@"ish-rootfs" withExtension:@"tar.gz"];
    if (archive == nil) return nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:archive.path error:nil];
    NSNumber *size = attrs[NSFileSize];
    return size != nil ? [NSString stringWithFormat:@"size-%llu", size.unsignedLongLongValue] : @"unknown";
}

#pragma mark memory governor

// The kernel admits guest memory by one of two rules. With no readings from the
// host it counts what is COMMITTED against a fixed ledger, and V8 commits about
// 640 MB of cage at startup while dirtying a few tens: `node -e ""` could not
// create its worker threads and aborted. With readings it goes by the app's real
// footprint against its real limit. Same feed as the fork's own iOS app
// (`ish/src/ish-arm64/app/AppDelegate.m`, `ish_memory_governor_tick`).
static void ISHMemoryGovernorTick(bool pressureCritical) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        footprint = info.phys_footprint;
    }
    if (footprint == 0) return; // the kernel's staleness rule handles a dead feed
#if TARGET_OS_SIMULATOR
    // `os_proc_available_memory` has no limit to report on a simulator. Same
    // share of the machine's RAM as the fork's command-line build.
    uint64_t ram = 0;
    size_t length = sizeof(ram);
    if (sysctlbyname("hw.memsize", &ram, &length, NULL, 0) != 0 || ram == 0) return;
    uint64_t limit = (uint64_t)((double)ram * 0.8);
    uint64_t available = limit > footprint ? limit - footprint : 0;
    ish_set_memory_status(limit, available, pressureCritical);
#else
    uint64_t available = (uint64_t)os_proc_available_memory();
    if (available == 0) return;
    ish_set_memory_status(footprint + available, available, pressureCritical);
#endif
}

/// The first reading is synchronous: the guest's first process must already be
/// admitted by the footprint rule.
static void ISHMemoryGovernorStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ ISHMemoryGovernorTick(false); });
        dispatch_resume(timer);
        static dispatch_source_t pressure;
        pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                          DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, queue);
        dispatch_source_set_event_handler(pressure, ^{
            ISHMemoryGovernorTick((dispatch_source_get_data(pressure) & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0);
        });
        dispatch_resume(pressure);
    });
    ISHMemoryGovernorTick(false);
}

#pragma mark boot

- (void)boot:(void (^)(NSError *_Nullable))completion {
    dispatch_async(_guestQueue, ^{
        NSError *error = [self bootOnQueue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(error);
        });
    });
}

/// The eight-step boot from Docs/ISH_SANDBOX_PORT.md. Runs on _guestQueue.
/// Every step is ordered: mount before PID 1 (the device-node calls need a
/// valid `current`), procfs before the exit hook (the hook is used by waitpid
/// loops that read /proc), and the tty driver before create_stdio.
- (NSError *)bootOnQueue {
    if (_booted) return nil;

    NSError *error = [self ensureRootfsInstalled];
    if (error) {
        [self setState:ISHGuestStateFailed detail:error.localizedDescription];
        return error;
    }

    NSTimeInterval bootStart = [NSDate timeIntervalSinceReferenceDate];

    // --- 1. install the crash handler and the embedded die handler ---------
    // Before anything else touches the kernel: a die() during mount_root must
    // still be survivable.
    die_handler = dsh_die_handler;
    exit_hook = dsh_exit_hook;

    // --- 2. mount fakefs and register its canonical host path --------------
    [self setState:ISHGuestStateMounting detail:@"mounting the fakefs"];
    NSString *dataPath = [[_rootPath stringByAppendingPathComponent:@"data"] copy];
    int err = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    if (err < 0) {
        [self setState:ISHGuestStateFailed
                detail:[NSString stringWithFormat:@"mount_root failed: %d", err]];
        return [NSError errorWithDomain:@"dshportc.guest" code:10
                               userInfo:@{NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:@"mount_root failed: %d", err]}];
    }

    // fakefs suppresses bind mounts that would contain the rootfs itself; it
    // needs the canonical path to compare against, which on this platform means
    // resolving the /private prefix.
    char canonical[PATH_MAX];
    if (realpath(dataPath.fileSystemRepresentation, canonical) != NULL) {
        fakefs_set_rootfs_data_path(canonical);
    }

    // --- 3. create PID 1 and the device nodes ------------------------------
    [self setState:ISHGuestStateBooting detail:@"creating PID 1"];
    ISHMemoryGovernorStart();
    err = become_first_process();
    if (err < 0) {
        [self setState:ISHGuestStateFailed
                detail:[NSString stringWithFormat:@"become_first_process failed: %d", err]];
        return [NSError errorWithDomain:@"dshportc.guest" code:11
                               userInfo:@{NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:@"become_first_process failed: %d", err]}];
    }
    current->thread = pthread_self();

    // Only the nodes a headless command runner needs. The clipboard and
    // location devices some forks add are deliberately absent: they are
    // world-readable to any guest process and bypass every capability gate.
    generic_mknodat(AT_PWD, "/dev/null",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full",    S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random",  S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/tty",     S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx",    S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    // --- 4. rootfs overlay -------------------------------------------------
    // Nothing to apply: this build has no fetch polyfill or profile overlay in
    // the guest. The step exists in the canonical order so the omission is
    // visible rather than looking like an oversight.

    // --- 5. procfs and devpts ----------------------------------------------
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // --- 6. resolv.conf ----------------------------------------------------
    // Left to the image: build-rootfs.sh writes /etc/resolv.conf into the
    // guest, and a bind mount from the host would need the container's DNS
    // configuration, which on the simulator is the host's. Binding it here
    // would also make the file un-editable from inside the guest, which is the
    // opposite of what a debug console is for.

    // --- 7. exit hook (already installed in step 1) and the tty driver ------
    tty_drivers[TTY_CONSOLE_MAJOR] = &dsh_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);

    // --- 8. init stdio, then the kernel counts as booted -------------------
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        // Not fatal: the executor gives each command its own pipes, and stdio
        // on PID 1 is only used by the kernel's own printk path.
        [[ISHGuestLog shared] append:[NSString stringWithFormat:
            @"[guest] create_stdio failed: %d (non-fatal)", err]];
    }

    _bootSeconds = [NSDate timeIntervalSinceReferenceDate] - bootStart;
    _booted = YES;
    [self setState:ISHGuestStateReady
            detail:[NSString stringWithFormat:@"booted in %.3f s", _bootSeconds]];
    return nil;
}

#pragma mark running commands

- (void)runCommand:(NSString *)command
           timeout:(NSTimeInterval)timeout
         lineBlock:(ISHGuestLineBlock)lineBlock
        completion:(ISHGuestCompletionBlock)completion {
    dispatch_async(_guestQueue, ^{
        NSError *error = [self bootOnQueue];
        if (error) {
            ISHGuestResult *result = [[ISHGuestResult alloc] init];
            result.exitCode = -1;
            result.pid = -1;
            result.launchError = error.localizedDescription;
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result); });
            return;
        }
        ISHGuestResult *result = [self runCommandOnQueue:command
                                                timeout:timeout
                                              lineBlock:lineBlock];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result); });
    });
}

/// Start a guest process, collect its output, wait for it to exit. On _guestQueue.
- (ISHGuestResult *)runCommandOnQueue:(NSString *)command
                              timeout:(NSTimeInterval)timeout
                            lineBlock:(ISHGuestLineBlock)lineBlock {
    ISHGuestResult *result = [[ISHGuestResult alloc] init];
    result.exitCode = -1;
    result.pid = -1;

    if (_commandRunning) {
        result.launchError = @"a guest command is already running; this build runs one at a time";
        return result;
    }

    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        int saved = errno;
        if (stdoutPipe[0] >= 0) { close(stdoutPipe[0]); close(stdoutPipe[1]); }
        result.launchError = [NSString stringWithFormat:@"pipe() failed: %s", strerror(saved)];
        return result;
    }
    fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK);

    struct task *savedCurrent = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = savedCurrent;
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        close(stderrPipe[0]); close(stderrPipe[1]);
        result.launchError = [NSString stringWithFormat:@"become_new_init_child failed: %d", err];
        return result;
    }
    struct task *task = current;

    // Each new task gets /dev/null on fd 0 and the pipes on 1 and 2, so a
    // command that reads stdin sees EOF instead of blocking on the app's stdin.
    struct fd *nullFD = adhoc_fd_create(&realfs_fdops);
    if (nullFD != NULL) {
        nullFD->real_fd = open("/dev/null", O_RDONLY);
        task->files->files[0] = nullFD;
    }
    struct fd *outFD = adhoc_fd_create(&realfs_fdops);
    if (outFD != NULL) {
        outFD->real_fd = dup(stdoutPipe[1]);
        task->files->files[1] = outFD;
    }
    struct fd *errFD = adhoc_fd_create(&realfs_fdops);
    if (errFD != NULL) {
        errFD->real_fd = dup(stderrPipe[1]);
        task->files->files[2] = errFD;
    }
    close(stdoutPipe[1]); stdoutPipe[1] = -1;
    close(stderrPipe[1]); stderrPipe[1] = -1;

    // argv and envp are the double-NUL-terminated byte blobs do_execve expects.
    char argv[8192];
    size_t pos = 0;
    const char *parts[3] = {"/bin/sh", "-c", command.UTF8String ?: ""};
    for (int i = 0; i < 3; i++) {
        size_t len = strlen(parts[i]) + 1;
        if (pos + len + 1 > sizeof(argv)) {
            current = savedCurrent;
            close(stdoutPipe[0]); close(stderrPipe[0]);
            result.launchError = @"command too long";
            return result;
        }
        memcpy(argv + pos, parts[i], len);
        pos += len;
    }
    argv[pos] = '\0';

    const char *envp = "TERM=xterm-256color\0"
                       "HOME=/root\0"
                       "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
                       "LANG=C.UTF-8\0"
                       "\0";

    __atomic_store_n(&g_exitPending, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_exitedPID, 0, __ATOMIC_SEQ_CST);

    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    err = do_execve("/bin/sh", 3, argv, envp);
    if (err < 0) {
        current = savedCurrent;
        close(stdoutPipe[0]); close(stderrPipe[0]);
        result.launchError = [NSString stringWithFormat:
            @"do_execve /bin/sh failed: %d (does the guest have /bin/sh?)", err];
        return result;
    }

    int guestPID = task->pid;
    result.pid = guestPID;
    _commandPID = guestPID;

    err = task_start(task);
    current = savedCurrent;
    if (err < 0) {
        close(stdoutPipe[0]); close(stderrPipe[0]);
        result.launchError = [NSString stringWithFormat:@"task_start failed: %d", err];
        return result;
    }

    _commandRunning = YES;
    NSMutableData *stdoutData = [NSMutableData data];
    NSMutableData *stderrData = [NSMutableData data];

    // Drain both pipes until EOF. The process is reaped through the exit hook,
    // but the reader must not stop at exit: the tail of the output is usually
    // still sitting in the pipe buffer when the process dies.
    BOOL exited = NO;
    NSTimeInterval deadline = timeout > 0 ? started + timeout : 0;
    BOOL timedOut = NO;
    char buffer[8192];

    while (YES) {
        BOOL readSomething = NO;
        for (int which = 0; which < 2; which++) {
            int fd = which == 0 ? stdoutPipe[0] : stderrPipe[0];
            if (fd < 0) continue;
            ssize_t n = read(fd, buffer, sizeof(buffer));
            if (n > 0) {
                readSomething = YES;
                [(which == 0 ? stdoutData : stderrData) appendBytes:buffer length:(NSUInteger) n];
            } else if (n == 0) {
                close(fd);
                if (which == 0) stdoutPipe[0] = -1; else stderrPipe[0] = -1;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                close(fd);
                if (which == 0) stdoutPipe[0] = -1; else stderrPipe[0] = -1;
            }
        }

        if (__atomic_load_n(&g_exitPending, __ATOMIC_SEQ_CST) &&
            __atomic_load_n(&g_exitedPID, __ATOMIC_SEQ_CST) == guestPID) {
            exited = YES;
        }

        if (exited && stdoutPipe[0] < 0 && stderrPipe[0] < 0) break;

        if (timeout > 0 && !exited && [NSDate timeIntervalSinceReferenceDate] > deadline) {
            timedOut = YES;
            // SIGKILL only: this build does not yet walk the process group, and
            // a SIGTERM that a shell ignores would leave the loop spinning.
            [self signalOnQueue:SIGKILL_ pid:guestPID];
            break;
        }

        if (!readSomething) usleep(exited ? 1000 : 5000);
    }

    if (stdoutPipe[0] >= 0) close(stdoutPipe[0]);
    if (stderrPipe[0] >= 0) close(stderrPipe[0]);

    _commandRunning = NO;
    _commandPID = 0;

    // Give the exit hook a moment to land if the pipes closed first: closing
    // both pipes means the process is gone, but its exit status is recorded by
    // the hook on the guest thread.
    NSTimeInterval waitUntil = [NSDate timeIntervalSinceReferenceDate] + 2.0;
    while (!exited && [NSDate timeIntervalSinceReferenceDate] < waitUntil) {
        if (__atomic_load_n(&g_exitPending, __ATOMIC_SEQ_CST) &&
            __atomic_load_n(&g_exitedPID, __ATOMIC_SEQ_CST) == guestPID) {
            exited = YES;
            break;
        }
        usleep(2000);
    }

    result.duration = [NSDate timeIntervalSinceReferenceDate] - started;
    result.timedOut = timedOut;
    result.standardOutput = [self stringFromData:stdoutData];
    result.standardError = [self stringFromData:stderrData];
    result.output = [result.standardOutput stringByAppendingString:result.standardError];

    // The hook's `code` is a raw wait status; present it the way a shell would.
    int status = __atomic_load_n(&g_exitedStatus, __ATOMIC_SEQ_CST);
    if (exited) {
        result.exitCode = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : (128 + (status & 0x7f));
    } else if (timedOut) {
        result.exitCode = 124; // the conventional timeout code
    } else {
        result.exitCode = -1;
        result.launchError = @"the guest process never reported an exit";
    }

    if (lineBlock) {
        // Line callbacks are delivered after the fact here. Streaming them in
        // real time is the Node channel's job (step 3); for a debug console the
        // finished buffers are equivalent and much easier to get right.
        for (NSString *line in [result.standardOutput componentsSeparatedByString:@"\n"]) {
            if (line.length) dispatch_async(dispatch_get_main_queue(), ^{ lineBlock(line, NO); });
        }
        for (NSString *line in [result.standardError componentsSeparatedByString:@"\n"]) {
            if (line.length) dispatch_async(dispatch_get_main_queue(), ^{ lineBlock(line, YES); });
        }
    }

    return result;
}

- (NSString *)stringFromData:(NSData *)data {
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

#pragma mark streaming exec (the Node channel's entry point)


- (void)execRequest:(ISHGuestExecRequest *)request
         chunkBlock:(ISHGuestChunkBlock)chunkBlock
          lineBlock:(ISHGuestLineBlock)lineBlock
         completion:(void (^)(ISHGuestExecResult *))completion {
    NSString *execID = request.execID.length > 0
        ? request.execID
        : [[NSUUID UUID] UUIDString];

    // Boot first, then start. Everything that touches `current` stays on the
    // guest queue until the pipes exist; the drain afterwards runs on its own
    // thread so the queue is free for cancel and for the next exec.
    dispatch_async(_guestQueue, ^{
        NSError *bootError = [self bootOnQueue];
        if (bootError != nil) {
            ISHGuestExecResult *result = [[ISHGuestExecResult alloc] init];
            result.execID = execID;
            result.exitCode = -1;
            result.pid = -1;
            result.launchError = bootError.localizedDescription;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(result);
            });
            return;
        }

        ISHGuestExecResult *startFailure = nil;
        DSHGuestRun *run = [self startExecOnQueue:request
                                           execID:execID
                                       chunkBlock:chunkBlock
                                        lineBlock:lineBlock
                                          failure:&startFailure];
        if (run == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(startFailure);
            });
            return;
        }

        // The drain runs on its own thread. It may not touch `current` or any
        // other kernel state — the guest queue owns that — it only reads the
        // two host pipes and waits for the exit slot.
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            [self drainExec:run chunkBlock:chunkBlock lineBlock:lineBlock completion:completion];
        }];
        thread.name = @"guest-exec";
        thread.stackSize = 1 << 20;
        [thread start];
    });
}


// The in-flight streaming exec, for cancel.
//
// A lock rather than an atomic pointer: Objective-C object pointers are not
// valid operands for the GCC `__atomic_*` builtins under ARC (the compiler
// rejects `&someAtomicObjectPointer`), and the contention here is nil — writes
// happen twice per exec. The lock is held only to swap a pointer.
static DSHGuestRun *g_runningRun = nil;
static BOOL g_execRunning = NO;
static pthread_mutex_t g_runLock = PTHREAD_MUTEX_INITIALIZER;

static DSHGuestRun *dsh_running_run(void) {
    pthread_mutex_lock(&g_runLock);
    DSHGuestRun *run = g_runningRun;
    pthread_mutex_unlock(&g_runLock);
    return run;
}

static void dsh_set_running_run(DSHGuestRun *run) {
    pthread_mutex_lock(&g_runLock);
    g_runningRun = run;
    g_execRunning = run != nil;
    pthread_mutex_unlock(&g_runLock);
}

static BOOL dsh_exec_running(void) {
    pthread_mutex_lock(&g_runLock);
    BOOL running = g_execRunning;
    pthread_mutex_unlock(&g_runLock);
    return running;
}

/// Start the guest process. On _guestQueue. Returns nil with `failure` set.
- (DSHGuestRun *)startExecOnQueue:(ISHGuestExecRequest *)request
                           execID:(NSString *)execID
                       chunkBlock:(ISHGuestChunkBlock)chunkBlock
                        lineBlock:(ISHGuestLineBlock)lineBlock
                          failure:(ISHGuestExecResult **)failure {
    ISHGuestExecResult *failed = [[ISHGuestExecResult alloc] init];
    failed.execID = execID;
    failed.exitCode = -1;
    failed.pid = -1;

    if (dsh_exec_running()) {
        failed.launchError = @"a guest command is already running";
        *failure = failed;
        return nil;
    }

    DSHGuestRun *run = [[DSHGuestRun alloc] init];
    run.execID = execID;
    run.timeout = request.timeout;
    run.maxBytes = request.maxOutputBytes > 0 ? request.maxOutputBytes : kDefaultExecMaxOutputBytes;
    run.retainOutput = request.retainOutput;
    run.chunkBlock = [chunkBlock copy];
    run.lineBlock = [lineBlock copy];

    int outPipe[2] = {-1, -1};
    int errPipe[2] = {-1, -1};
    int inPipe[2] = {-1, -1};
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0 || pipe(inPipe) != 0) {
        int saved = errno;
        for (int i = 0; i < 2; i++) {
            if (outPipe[i] >= 0) close(outPipe[i]);
            if (errPipe[i] >= 0) close(errPipe[i]);
            if (inPipe[i] >= 0) close(inPipe[i]);
        }
        failed.launchError = [NSString stringWithFormat:@"pipe() failed: %s", strerror(saved)];
        *failure = failed;
        return nil;
    }
    // Non-blocking reads: the drain loop must be able to check the deadline and
    // the exit slot while both pipes are idle.
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(inPipe[0], F_SETFL, O_NONBLOCK);
    // Non-blocking write end too: a guest that never reads stdin must not be
    // able to stall the host thread that is feeding it.
    fcntl(inPipe[1], F_SETFL, O_NONBLOCK);
    // If the host side dies, the guest should see EPIPE rather than SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    struct task *savedCurrent = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = savedCurrent;
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        close(inPipe[0]); close(inPipe[1]);
        failed.launchError = [NSString stringWithFormat:@"become_new_init_child failed: %d", err];
        *failure = failed;
        return nil;
    }
    struct task *task = current;

    // Working directory. Left at the guest root when the caller did not ask for
    // one, which matches what /bin/sh -c would do with no `cd`.
    if (request.workingDirectory.length > 0) {
        // Own the bytes: the C helper takes a `const char *` and ARC will not
        // hand one out implicitly from an NSString property access.
        const char *cwd = strdup(request.workingDirectory.UTF8String ?: "");
        int chdirErr = cwd != NULL ? sys_chdir_guest(cwd) : _ENOMEM;
        free((void *) cwd);
        if (chdirErr != 0) {
            // FATAL, and it used to not be. Running the command anyway meant it
            // ran in whatever directory the fresh task inherited (the guest root,
            // or the workspace a previous exec left behind) while the caller
            // believed it was somewhere else: a `rm -rf *` aimed at `/tmp` would
            // have hit the user's project. A command whose cwd cannot be entered
            // must not start; the caller gets a launch error naming the path,
            // which the channel reports as "the command never started".
            [[ISHGuestLog shared] append:[NSString stringWithFormat:
                @"[guest] exec: chdir(%@) failed: %d; command not run", request.workingDirectory, chdirErr]];
            current = savedCurrent;
            close(outPipe[0]); close(outPipe[1]);
            close(errPipe[0]); close(errPipe[1]);
            close(inPipe[0]); close(inPipe[1]);
            failed.launchError = [NSString stringWithFormat:
                @"cannot enter working directory %@ in the guest (chdir failed: %d); the command was not run",
                request.workingDirectory, chdirErr];
            *failure = failed;
            return nil;
        }
    }

    // stdio: /dev/null on 0 when no stdin was supplied, the pipes on 1 and 2.
    //
    // WHY THE CONDITIONAL MATTERS, AND WHY IT IS NOT AN OPTIMISATION. This used to
    // be an unconditional `dup(inPipe[0])`, with the pipe closed immediately
    // afterwards when there was no data. The child's fd 0 was then a FIFO, and a
    // FIFO is what makes ripgrep change its mind about what it was asked to do:
    //
    //   grep_cli: found that is_file=false, is_fifo=true ...
    //   hiargs:   heuristic chose to search stdin
    //
    // So `rg --json --regexp=X` (no path) read the closed pipe, found nothing, and
    // exited 1 having searched zero files — `searches: 0, bytes_searched: 0`. That
    // is the whole of the phone's "`glob`/`grep` do not work" report for the
    // no-path case: DSH's `grep` tool passes no path when the model does not name
    // one, and the tool read rg's empty answer as "no matches". (`--files` still
    // worked, because listing never consults stdin — which is exactly why the two
    // tools disagreed and the cause looked like the directory walk.)
    //
    // `/dev/null` is a character device: `is_file` stays false but `is_fifo` is
    // also false, so rg falls back to searching `./` — measured in the emulator
    // both ways. When stdin data IS supplied the pipe is still the only correct
    // answer, so the conditional leaves that path untouched.
    struct fd *inFD = adhoc_fd_create(&realfs_fdops);
    if (inFD != NULL) {
        if (request.stdin.length > 0) {
            inFD->real_fd = dup(inPipe[0]);
        } else {
            inFD->real_fd = open("/dev/null", O_RDONLY);
        }
        task->files->files[0] = inFD;
    }
    struct fd *outFD = adhoc_fd_create(&realfs_fdops);
    if (outFD != NULL) {
        outFD->real_fd = dup(outPipe[1]);
        task->files->files[1] = outFD;
    }
    struct fd *errFD = adhoc_fd_create(&realfs_fdops);
    if (errFD != NULL) {
        errFD->real_fd = dup(errPipe[1]);
        task->files->files[2] = errFD;
    }
    close(outPipe[1]);
    close(errPipe[1]);
    close(inPipe[0]);

    // argv: either the caller's explicit vector or /bin/sh -c <command>.
    // The kernel wants one double-NUL-terminated blob, so a long argv has to be
    // heap-allocated rather than stacked — 8 KiB is not enough for a realistic
    // command line.
    NSArray<NSString *> *argvStrings = request.argv.count > 0
        ? request.argv
        : @[ @"/bin/sh", @"-c", request.command ?: @"" ];

    size_t argvBytes = 1;
    for (NSString *part in argvStrings) argvBytes += strlen(part.UTF8String ?: "") + 1;
    char *argvBlob = malloc(argvBytes);
    if (argvBlob == NULL) {
        current = savedCurrent;
        close(outPipe[0]); close(errPipe[0]); close(inPipe[1]);
        failed.launchError = @"out of memory building argv";
        *failure = failed;
        return nil;
    }
    size_t pos = 0;
    for (NSString *part in argvStrings) {
        const char *bytes = part.UTF8String ?: "";
        size_t len = strlen(bytes) + 1;
        memcpy(argvBlob + pos, bytes, len);
        pos += len;
    }
    argvBlob[pos] = '\0';

    // Environment: the defaults the debug console already used, plus overrides.
    NSMutableArray<NSString *> *envStrings = [NSMutableArray arrayWithArray:@[
        @"TERM=xterm-256color",
        @"HOME=/root",
        @"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"LANG=C.UTF-8",
    ]];
    for (NSString *extra in request.environment) {
        if (extra.length == 0) continue;
        NSString *key = [extra componentsSeparatedByString:@"="].firstObject;
        // Later entries win, matching how a shell treats a repeated export.
        NSUInteger existing = NSNotFound;
        for (NSUInteger i = 0; i < envStrings.count; i++) {
            if ([envStrings[i] hasPrefix:[key stringByAppendingString:@"="]]) {
                existing = i;
                break;
            }
        }
        if (existing != NSNotFound) [envStrings replaceObjectAtIndex:existing withObject:extra];
        else [envStrings addObject:extra];
    }
    size_t envBytes = 1;
    for (NSString *part in envStrings) envBytes += strlen(part.UTF8String ?: "") + 1;
    char *envBlob = malloc(envBytes);
    if (envBlob == NULL) {
        free(argvBlob);
        current = savedCurrent;
        close(outPipe[0]); close(errPipe[0]); close(inPipe[1]);
        failed.launchError = @"out of memory building the environment";
        *failure = failed;
        return nil;
    }
    pos = 0;
    for (NSString *part in envStrings) {
        const char *bytes = part.UTF8String ?: "";
        size_t len = strlen(bytes) + 1;
        memcpy(envBlob + pos, bytes, len);
        pos += len;
    }
    envBlob[pos] = '\0';

    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    // Copy the path out first: passing an Objective-C expression that yields a
    // borrowed C pointer straight into do_execve is a lifetime question ARC
    // refuses to answer, and the fix is to own the bytes.
    const char *execPath = strdup(argvStrings.firstObject.UTF8String ?: "/bin/sh");
    const char *execPathOwned = execPath;
    err = do_execve(execPathOwned, (int) argvStrings.count, argvBlob, envBlob);
    free((void *) execPath);
    if (err < 0) {
        free(argvBlob);
        free(envBlob);
        current = savedCurrent;
        close(outPipe[0]); close(errPipe[0]); close(inPipe[1]);
        failed.launchError = [NSString stringWithFormat:
            @"do_execve %@ failed: %d", argvStrings.firstObject, err];
        *failure = failed;
        return nil;
    }
    // do_execve copies nothing: the blobs must stay alive until the new program
    // has read them, which happens inside task_start's thread. They are freed by
    // the drain thread's cleanup because a guest `exec` of /bin/sh keeps them on
    // the kernel's stack only during the execve call itself.
    free(argvBlob);
    free(envBlob);

    int guestPID = task->pid;
    // Register the exit slot BEFORE starting the thread: a command like `true`
    // can exit between task_start returning and anything else running.
    int slot = dsh_exit_slot_register(guestPID);
    if (slot < 0) {
        current = savedCurrent;
        close(outPipe[0]); close(errPipe[0]); close(inPipe[1]);
        failed.launchError = @"no free guest exit slot (too many concurrent execs)";
        *failure = failed;
        return nil;
    }

    // Its own session, so that the children it leaves behind can still be found
    // once it has exited; see `signalSessionOnQueue:signal:`.
    task_setsid(task);

    err = task_start(task);
    current = savedCurrent;
    if (err < 0) {
        dsh_exit_slot_release(slot);
        close(outPipe[0]); close(errPipe[0]); close(inPipe[1]);
        failed.launchError = [NSString stringWithFormat:@"task_start failed: %d", err];
        *failure = failed;
        return nil;
    }

    run.stdoutRead = outPipe[0];
    run.stderrRead = errPipe[0];
    run.stdinWrite = inPipe[1];
    run.guestPID = guestPID;
    run.exitSlot = slot;
    run.started = started;
    run.stdinData = [request.stdin copy] ?: [NSData data];
    run.stdinWritten = 0;

    dsh_set_running_run(run);

    // stdin is written from the DRAIN thread, not here.
    //
    // The old code wrote the whole request synchronously on this (serialized)
    // guest queue. That cannot work for a heredoc: `cat > a.sh <<'EOF'` is a
    // command whose stdin the *shell* reads while it is running, and the shell
    // only gets scheduled when this queue is free again. Writing here would
    // therefore block the queue against the very process that has to consume
    // the bytes, and a payload larger than the pipe buffer (64 KiB) could never
    // be delivered at all. The drain thread already owns the two read ends and
    // runs off-queue, so it owns the write end too: interleaving one non-blocking
    // write per poll is enough, and closing that end when the buffer is empty is
    // what gives the child a real EOF.
    if (run.stdinData.length == 0) {
        // No stdin at all: close immediately so a `cat` sees EOF at once
        // rather than after the first poll interval.
        close(run.stdinWrite);
        run.stdinWrite = -1;
        run.stdinClosed = YES;
    }

    return run;
}

/// chdir inside the guest, on the current guest task. Returns 0 or an errno.
///
/// Split out because sys_chdir reads its path from guest memory; here the path
/// comes from the host as a C string.
int sys_chdir_guest(const char *path) {
    struct fd *dir = NULL;
    char normalized[MAX_PATH];
    int nofollow = 0;
    int err = path_normalize(AT_PWD, path, normalized, nofollow);
    if (err < 0) return err;
    struct mount *mount = find_mount_and_trim_path(normalized);
    if (mount == NULL) return _ENOENT;
    struct statbuf stat = {};
    err = mount->fs->stat(mount, normalized, &stat);
    mount_release(mount);
    if (err < 0) return err;
    if (!(stat.mode & S_IFDIR)) return _ENOTDIR;
    dir = generic_open(normalized, O_RDONLY_, 0);
    if (IS_ERR(dir)) return PTR_ERR(dir);
    fs_chdir(current->fs, dir);
    return 0;
}

/// Read both pipes until the child has exited and both are at EOF, then finish.
/// Runs on its own thread; never touches `current` or any kernel state.
///
/// Three things here are deliberate and each fixes a specific failure:
///
///   1. **stdin is written here**, not on the guest queue. A heredoc's bytes
///      have to reach the shell *while it runs*; writing them from the
///      serialized queue would block that queue against the consumer.
///   2. **EOF is a real `read() == 0`**, not a timer. The previous version
///      stopped after a fixed 100 ms delay whenever the process had exited,
///      which silently cut the tail of any command whose output took longer
///      than that to drain.
///   3. **Termination is a ladder, not a repeated SIGKILL**: SIGTERM to the
///      whole recorded process tree, a grace window, then SIGKILL to whoever
///      is still the same task. PID 1 is never signalled.
- (void)drainExec:(DSHGuestRun *)run
       chunkBlock:(ISHGuestChunkBlock)chunkBlock
        lineBlock:(ISHGuestLineBlock)lineBlock
       completion:(void (^)(ISHGuestExecResult *))completion {
    char buffer[16384];
    BOOL exited = NO;
    // Line assembly, per stream, so a `\n` split across two reads is still one
    // line. This is only for the debug console; the channel uses chunks.
    NSMutableData *stdoutLine = [NSMutableData data];
    NSMutableData *stderrLine = [NSMutableData data];

    void (^emitLine)(NSMutableData *, BOOL) = ^(NSMutableData *accum, BOOL isErr) {
        if (lineBlock == nil || accum.length == 0) { [accum setLength:0]; return; }
        NSString *text = [[NSString alloc] initWithData:accum encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:accum encoding:NSISOLatin1StringEncoding];
        [accum setLength:0];
        if (text.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ lineBlock(text, isErr); });
        }
    };

    // The SIGTERM → SIGKILL ladder, run at most once per exec.
    //
    // `run.terminationStarted` is the guard: the old loop called SIGKILL on
    // every poll while `cancelled` was set, which is both wasteful and — worse —
    // can kill an unrelated guest process that inherited the recycled PID.
    void (^startTermination)(void) = ^{
        if (run.terminationStarted) return;
        run.terminationStarted = YES;
        run.terminationStartedAt = [NSDate timeIntervalSinceReferenceDate];
        dispatch_sync(self->_guestQueue, ^{
            [self signalProcessTreeOnQueue:run.guestPID signal:SIGTERM_];
            [self signalSessionOnQueue:run.guestPID signal:SIGTERM_];
        });
    };

    while (YES) {
        BOOL readSomething = NO;

        // ---- stdin: one non-blocking write per poll -----------------------
        // Done before the reads so a command that is waiting for its heredoc
        // gets the bytes on the first iteration rather than the second.
        if (!run.stdinClosed && run.stdinWrite >= 0) {
            if (run.stdinWritten >= run.stdinData.length) {
                // Everything handed over. Closing the write end is the EOF the
                // child is waiting for; leaving it open is what made `cat` hang.
                close(run.stdinWrite);
                run.stdinWrite = -1;
                run.stdinClosed = YES;
            } else {
                const uint8_t *bytes = run.stdinData.bytes;
                ssize_t written = write(run.stdinWrite,
                                        bytes + run.stdinWritten,
                                        run.stdinData.length - run.stdinWritten);
                if (written > 0) {
                    run.stdinWritten += (NSUInteger) written;
                    readSomething = YES;
                } else if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                    // Pipe full; the child will drain it. Try again next poll.
                } else {
                    // EPIPE or a real error: the child stopped reading. Closing
                    // is the only honest answer; it is not an exec failure.
                    close(run.stdinWrite);
                    run.stdinWrite = -1;
                    run.stdinClosed = YES;
                }
            }
        }

        for (int which = 0; which < 2; which++) {
            int fd = which == 0 ? run.stdoutRead : run.stderrRead;
            if (fd < 0) continue;
            ssize_t n = read(fd, buffer, sizeof(buffer));
            if (n > 0) {
                readSomething = YES;
                NSData *chunk = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger) n freeWhenDone:NO];
                // Chunk callback fires first, before any decoding: the Node side
                // does incremental UTF-8 so a split character survives.
                if (chunkBlock != nil) chunkBlock(chunk, which != 0);

                run.totalBytes += (unsigned long long) n;
                // Counting always happens; retaining is opt-in. The Node
                // channel sets retainOutput = NO because the Node-side
                // OutputCollector owns the cap and the complete-stream spill
                // promise — a second truncation here would make `spillPath`
                // a lie. The debug console keeps its copy.
                if (run.retainOutput) {
                    NSMutableData *sink = which == 0 ? run.stdoutData : run.stderrData;
                    NSUInteger room = run.maxBytes > sink.length ? run.maxBytes - sink.length : 0;
                    if (room > 0) {
                        [sink appendBytes:buffer length:MIN(room, (NSUInteger) n)];
                    }
                    if ((NSUInteger) n > room) run.truncated = YES;
                }

                if (lineBlock != nil) {
                    NSMutableData *lineAccum = which == 0 ? stdoutLine : stderrLine;
                    [lineAccum appendBytes:buffer length:(NSUInteger) n];
                    // Emit every complete line, keep the remainder.
                    NSUInteger consumed = 0;
                    const uint8_t *bytes = lineAccum.bytes;
                    for (NSUInteger i = 0; i < lineAccum.length; i++) {
                        if (bytes[i] == '\n') {
                            NSMutableData *line = [NSMutableData dataWithBytes:bytes + consumed
                                                                        length:i - consumed];
                            emitLine(line, which != 0);
                            consumed = i + 1;
                        }
                    }
                    if (consumed > 0) {
                        [lineAccum replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
                    }
                    // Keep line assembly bounded: a command that never emits a
                    // newline must not grow this without limit.
                    if (lineAccum.length > run.maxBytes) {
                        emitLine(lineAccum, which != 0);
                    }
                }
            } else if (n == 0) {
                // A real EOF. This is the only correct signal that the writer
                // side is done, and it is what the loop waits for.
                if (which == 0) { close(run.stdoutRead); run.stdoutRead = -1; }
                else { close(run.stderrRead); run.stderrRead = -1; }
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                if (which == 0) { close(run.stdoutRead); run.stdoutRead = -1; }
                else { close(run.stderrRead); run.stderrRead = -1; }
            }
        }

        struct dsh_exit_slot *slot = &g_exitSlots[run.exitSlot];
        if (__atomic_load_n(&slot->pending, __ATOMIC_SEQ_CST)) exited = YES;

        // Stop only when the process is gone AND both pipes reached EOF: the
        // tail of the output is usually still in the pipe when the process dies.
        if (exited && run.stdoutRead < 0 && run.stderrRead < 0) break;

        // The checks below do not stop at the process's own exit: a background
        // child can hold the pipes open long after its parent is gone, and this
        // loop then waits for an EOF that only a signal will bring.
        if (run.timeout > 0 && !run.terminationStarted &&
            [NSDate timeIntervalSinceReferenceDate] > run.started + run.timeout) {
            run.timedOut = YES;
            startTermination();
        }

        if (run.cancelled) startTermination();

        // A process that outlived SIGKILL's reach (it left the session) must not
        // keep the only guest command slot: stop reading and give the slot back.
        if (exited && run.terminationStarted &&
            [NSDate timeIntervalSinceReferenceDate] - run.terminationStartedAt > kTerminationGraceSeconds + kAbandonPipesAfterSeconds) {
            if (run.stdoutRead >= 0) { close(run.stdoutRead); run.stdoutRead = -1; }
            if (run.stderrRead >= 0) { close(run.stderrRead); run.stderrRead = -1; }
            break;
        }

        // Escalation. The grace window gives a cooperative process time to run
        // its own cleanup (a shell traps SIGTERM and kills its jobs); after it,
        // whatever is left gets SIGKILL.
        if (run.terminationStarted &&
            [NSDate timeIntervalSinceReferenceDate] - run.terminationStartedAt > kTerminationGraceSeconds) {
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            // Per-run, not a function static: a static would carry one exec's
            // last escalation time into the next exec and delay its SIGKILL.
            if (now - run.lastEscalationAt > 0.25) {
                run.lastEscalationAt = now;
                dispatch_sync(self->_guestQueue, ^{
                    [self signalProcessTreeOnQueue:run.guestPID signal:SIGKILL_];
                    [self signalSessionOnQueue:run.guestPID signal:SIGKILL_];
                });
            }
        }

        // A busy loop would burn a core inside an app that has to stay
        // foreground-viable; 4 ms is below the pipe's own wakeup granularity for
        // this workload and keeps a streaming command visibly streaming.
        if (!readSomething) usleep(exited ? 1000 : 4000);
    }

    // Both pipes are closed, but the exit hook may still be about to run.
    if (!exited) {
        NSTimeInterval waitUntil = [NSDate timeIntervalSinceReferenceDate] + 2.0;
        struct dsh_exit_slot *slot = &g_exitSlots[run.exitSlot];
        while ([NSDate timeIntervalSinceReferenceDate] < waitUntil) {
            if (__atomic_load_n(&slot->pending, __ATOMIC_SEQ_CST)) { exited = YES; break; }
            usleep(2000);
        }
    }

    if (stdoutLine.length > 0) emitLine(stdoutLine, NO);
    if (stderrLine.length > 0) emitLine(stderrLine, YES);

    int status = __atomic_load_n(&g_exitSlots[run.exitSlot].status, __ATOMIC_SEQ_CST);
    int exitCode;
    if (exited) {
        exitCode = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : (128 + (status & 0x7f));
    } else if (run.timedOut) {
        exitCode = 124;
    } else {
        exitCode = -1;
    }

    ISHGuestExecResult *result = [[ISHGuestExecResult alloc] init];
    result.execID = run.execID;
    result.pid = run.guestPID;
    result.exitCode = exitCode;
    result.duration = [NSDate timeIntervalSinceReferenceDate] - run.started;
    result.timedOut = run.timedOut;
    result.truncated = run.truncated;
    result.totalOutputBytes = run.totalBytes;
    result.standardOutput = [self stringFromData:run.stdoutData];
    result.standardError = [self stringFromData:run.stderrData];
    result.output = [result.standardOutput stringByAppendingString:result.standardError];
    if (!exited && !run.timedOut) {
        result.launchError = @"the guest process never reported an exit";
    }

    if (run.stdinWrite >= 0) close(run.stdinWrite);

    // Clean up the slot and the in-flight marker on the guest queue, so a cancel
    // arriving concurrently cannot see a half-freed run.
    dispatch_async(_guestQueue, ^{
        if (run.exitSlot >= 0) dsh_exit_slot_release(run.exitSlot);
        dsh_set_running_run(nil);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(result);
    });
}

- (BOOL)cancelExecWithID:(NSString *)execID {
    DSHGuestRun *run = dsh_running_run();
    if (run == NULL || ![run.execID isEqualToString:execID]) return NO;
    // Only request termination here. The drain thread owns the ladder
    // (SIGTERM → grace → SIGKILL over the process tree) because it is the only
    // place that also observes the pipes draining to EOF; signalling from this
    // side as well would race the escalation and could kill a recycled PID.
    run.cancelled = YES;
    return YES;
}

#pragma mark resolve and workspace binding

/// The guest's default PATH, used when a caller does not supply one.
///
/// Kept in one place because it is a *fact about this rootfs* (Alpine's
/// busybox layout), not a preference: `apk` puts applets in /bin and /sbin,
/// and this image also has /usr/bin and /usr/local/bin from the packages
/// RootfsPackages.md lists.
static NSString *const kGuestDefaultPath =
    @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

- (nullable NSString *)resolveExecutableNamed:(NSString *)name pathValue:(nullable NSString *)pathValue {
    if (name.length == 0) return nil;
    __block NSString *found = nil;
    dispatch_sync(_guestQueue, ^{
        NSError *bootError = [self bootOnQueue];
        if (bootError != nil) return;

        NSString *path = pathValue.length > 0 ? pathValue : kGuestDefaultPath;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if ([name isAbsolutePath] || [name containsString:@"/"]) {
            // A path is used as given, exactly like execvp: no PATH search.
            [candidates addObject:name];
        } else {
            for (NSString *dir in [path componentsSeparatedByString:@":"]) {
                if (dir.length == 0) continue;
                [candidates addObject:[dir stringByAppendingPathComponent:name]];
            }
        }

        for (NSString *candidate in candidates) {
            // stat() rather than access(), for two reasons: the guest runs as
            // root, so the kernel's own access_check() is a no-op and would
            // report every file as executable; and the mode bits are what a
            // caller deciding "can I run this" actually wants. The shape is the
            // same one resolveOnQueue uses, so both agree on what "exists" means.
            if ([self guestPathIsExecutableFile:candidate]) {
                found = candidate;
                return;
            }
        }
    });
    return found;
}

/// Whether `path` names a regular file with an execute bit, inside the guest.
///
/// Runs on the guest queue; uses init's identity for the lookup because the
/// kernel reads paths through the calling task's fs and init always has the
/// root mount registered.
- (BOOL)guestPathIsExecutableFile:(NSString *)path {
    if (path.length == 0) return NO;
    struct task *savedCurrent = current;
    struct task *init = pid_get_task(1);
    if (init == NULL) return NO;
    current = init;

    char normalized[MAX_PATH];
    int err = path_normalize(AT_PWD, path.fileSystemRepresentation, normalized, 0);
    if (err < 0) { current = savedCurrent; return NO; }

    struct mount *mount = find_mount_and_trim_path(normalized);
    if (mount == NULL) { current = savedCurrent; return NO; }
    struct statbuf stat = {};
    err = mount->fs->stat(mount, normalized, &stat);
    mount_release(mount);
    current = savedCurrent;
    if (err < 0) return NO;

    if ((stat.mode & S_IFMT) != S_IFREG) return NO;
    return (stat.mode & 0111) != 0;
}

- (void)resolvePath:(NSString *)path
         completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSString *requested = [path copy] ?: @"";
    dispatch_async(_guestQueue, ^{
        NSError *bootError = [self bootOnQueue];
        if (bootError != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@{ @"path": requested,
                              @"exists": @NO,
                              @"error": bootError.localizedDescription });
            });
            return;
        }

        NSDictionary *info = [self resolveOnQueue:requested];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(info); });
    });
}

/// stat + access inside the kernel, on the guest queue.
- (NSDictionary<NSString *, id> *)resolveOnQueue:(NSString *)path {
    if (path.length == 0) {
        return @{ @"path": @"", @"exists": @NO, @"error": @"empty path" };
    }

    // The kernel reads paths through the calling task's fs, so it needs a
    // `current`. Use init's identity for the probe: it has the root mount
    // registered and no state that a read-only lookup can disturb.
    struct task *savedCurrent = current;
    struct task *init = pid_get_task(1);
    if (init == NULL) {
        return @{ @"path": path, @"exists": @NO, @"error": @"the guest has no init task" };
    }
    current = init;

    char normalized[MAX_PATH];
    // N_SYMLINK_FOLLOW: resolve is asked about the file the caller would
    // actually open, so a symlink must be followed (that is also what
    // `access(X_OK)` does on a real system).
    int err = path_normalize(AT_PWD, path.fileSystemRepresentation, normalized, 0);
    if (err < 0) {
        current = savedCurrent;
        return @{ @"path": path, @"exists": @NO, @"errno": @(-err), @"error": dsh_errno_name(err) };
    }

    struct mount *mount = find_mount_and_trim_path(normalized);
    if (mount == NULL) {
        current = savedCurrent;
        return @{ @"path": path, @"exists": @NO, @"errno": @(_ENOENT), @"error": @"ENOENT" };
    }
    struct statbuf stat = {};
    err = mount->fs->stat(mount, normalized, &stat);
    mount_release(mount);
    current = savedCurrent;

    if (err < 0) {
        return @{ @"path": path, @"normalized": @(normalized),
                  @"exists": @NO, @"errno": @(-err), @"error": dsh_errno_name(err) };
    }

    // The guest runs as root, so the kernel's own access_check() is a no-op and
    // would report every file as executable. Report the mode bits instead, which
    // is what a caller deciding "can I run this" actually wants, and say which
    // answer came from where.
    BOOL isDir = (stat.mode & S_IFMT) == S_IFDIR;
    BOOL isReg = (stat.mode & S_IFMT) == S_IFREG;
    BOOL isLnk = (stat.mode & S_IFMT) == S_IFLNK;
    BOOL executable = (stat.mode & 0111) != 0;

    NSMutableDictionary *info = [@{
        @"path": path,
        @"normalized": @(normalized),
        @"exists": @YES,
        @"isDirectory": @(isDir),
        @"isRegularFile": @(isReg),
        @"isSymbolicLink": @(isLnk),
        @"executable": @(executable),
        @"mode": @(stat.mode & 07777),
        @"modeOctal": [NSString stringWithFormat:@"%04o", stat.mode & 07777],
        @"size": @(stat.size),
        @"uid": @(stat.uid),
        @"gid": @(stat.gid),
        @"dev": @(stat.dev),
        @"inode": @(stat.inode),
    } mutableCopy];

    // stat() vs fstat() agreement.
    //
    // This is not diagnostic decoration: coreutils' copy engine compares the
    // device and inode it got from stat() against the ones it got from fstat()
    // on the open descriptor, and reports "file was replaced while being copied"
    // when they differ. Reporting both here is what lets a caller tell whether a
    // path is safe to copy without running cp and reading its stderr.
    [self fillFstatForGuestPath:normalized into:info];
    return info;
}

/// Open a guest path and report what fstat() says, for the stat/fstat comparison.
- (void)fillFstatForGuestPath:(const char *)normalized into:(NSMutableDictionary *)info {
    struct task *savedCurrent = current;
    struct task *init = pid_get_task(1);
    if (init == NULL) return;
    current = init;

    struct fd *fd = generic_open(normalized, O_RDONLY_, 0);
    if (IS_ERR(fd)) {
        info[@"fstatError"] = dsh_errno_name(PTR_ERR(fd));
        current = savedCurrent;
        return;
    }
    struct statbuf fdStat = {};
    int err = fd->mount->fs->fstat(fd, &fdStat);
    fd_close(fd);
    current = savedCurrent;
    if (err < 0) {
        info[@"fstatError"] = dsh_errno_name(err);
        return;
    }
    info[@"fstatDev"] = @(fdStat.dev);
    info[@"fstatInode"] = @(fdStat.inode);
    info[@"statAndFstatDevAgree"] = @(fdStat.dev == (qword_t) [info[@"dev"] unsignedLongLongValue]);
    info[@"statAndFstatInodeAgree"] = @(fdStat.inode == (qword_t) [info[@"inode"] unsignedLongLongValue]);
}

- (void)bindMountGuestPath:(NSString *)guestPath
                  hostPath:(NSString *)hostPath
                 readWrite:(BOOL)readWrite
                completion:(void (^)(NSError *_Nullable))completion {
    NSString *guest = [guestPath copy] ?: @"";
    NSString *host = [hostPath copy] ?: @"";
    dispatch_async(_guestQueue, ^{
        NSError *bootError = [self bootOnQueue];
        if (bootError != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(bootError); });
            return;
        }

        NSError *error = [self bindMountOnQueue:guest hostPath:host readWrite:readWrite];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

- (NSError *)bindMountOnQueue:(NSString *)guestPath
                     hostPath:(NSString *)hostPath
                    readWrite:(BOOL)readWrite {
    if (guestPath.length == 0 || hostPath.length == 0) {
        return [NSError errorWithDomain:@"dshportc.guest" code:30
                               userInfo:@{NSLocalizedDescriptionKey:
                                              @"bind mount needs both a guest path and a host path"}];
    }

    // The kernel stats() and realpath()s the host path itself, so a missing
    // directory is a bind-mount failure rather than something to paper over.
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:hostPath isDirectory:&isDirectory]) {
        return [NSError errorWithDomain:@"dshportc.guest" code:31
                               userInfo:@{NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:
                                                  @"host path does not exist: %@", hostPath]}];
    }

    int err = fakefs_bind_mount(guestPath.fileSystemRepresentation,
                               hostPath.fileSystemRepresentation,
                               !readWrite);
    if (err < 0) {
        return [NSError errorWithDomain:@"dshportc.guest" code:32
                               userInfo:@{NSLocalizedDescriptionKey:
                                              [NSString stringWithFormat:
                                                  @"fakefs_bind_mount(%@ -> %@) failed: %d (%@)",
                                                  guestPath, hostPath, err, dsh_errno_name(err)]}];
    }

    _boundWorkspaceGuestPath = [guestPath copy];
    _boundWorkspaceHostPath = [hostPath copy];
    [[ISHGuestLog shared] append:[NSString stringWithFormat:
        @"[guest] bind mount %@ -> %@ (%@)", guestPath, hostPath,
        readWrite ? @"read-write" : @"read-only"]];
    return nil;
}

/// The kernel's errno values as their usual names. The names in the reply are
/// what a caller greps for; the numbers are already in `errno`.
NSString *dsh_errno_name(int err) {
    switch (err) {
        case 0: return @"0";
        case _EPERM: return @"EPERM";
        case _ENOENT: return @"ENOENT";
        case _ESRCH: return @"ESRCH";
        case _EINTR: return @"EINTR";
        case _EIO: return @"EIO";
        case _ENXIO: return @"ENXIO";
        case _E2BIG: return @"E2BIG";
        case _ENOEXEC: return @"ENOEXEC";
        case _EBADF: return @"EBADF";
        case _ECHILD: return @"ECHILD";
        case _EAGAIN: return @"EAGAIN";
        case _ENOMEM: return @"ENOMEM";
        case _EACCES: return @"EACCES";
        case _EFAULT: return @"EFAULT";
        case _EBUSY: return @"EBUSY";
        case _EEXIST: return @"EEXIST";
        case _ENOTDIR: return @"ENOTDIR";
        case _EISDIR: return @"EISDIR";
        case _EINVAL: return @"EINVAL";
        case _ENFILE: return @"ENFILE";
        case _EMFILE: return @"EMFILE";
        case _ENOSPC: return @"ENOSPC";
        case _EROFS: return @"EROFS";
        case _ENOTEMPTY: return @"ENOTEMPTY";
        case _ELOOP: return @"ELOOP";
        case _ENOSYS: return @"ENOSYS";
        case _ENOTSUP: return @"ENOTSUP";
        default: return [NSString stringWithFormat:@"errno %d", err];
    }
}

- (BOOL)sendSignal:(int)signal toPID:(int)pid {
    __block BOOL sent = NO;
    dispatch_sync(_guestQueue, ^{
        sent = [self signalOnQueue:signal pid:pid];
    });
    return sent;
}

- (BOOL)signalOnQueue:(int)signal pid:(int)pid {
    struct siginfo_ info = SIGINFO_NIL;
    BOOL sent = NO;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t) pid);
    if (task != NULL) {
        send_signal(task, signal, info);
        sent = YES;
    }
    unlock(&pids_lock);
    return sent;
}

/// Signal every guest process in `pid`'s tree. Must run on the guest queue.
///
/// The tree is re-walked on every call rather than cached: between SIGTERM and
/// SIGKILL a shell may have reaped its children and a new guest process may
/// have inherited the numbers, so a stale list would signal the wrong tasks.
- (NSUInteger)signalProcessTreeOnQueue:(int)pid signal:(int)signal {
    if (pid <= 0) return 0;
    int pids[DSH_MAX_TREE_PIDS];
    int count = 0;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    count = dsh_collect_process_tree(pid, pids, DSH_MAX_TREE_PIDS);
    for (int i = 0; i < count; i++) {
        struct task *task = pid_get_task((dword_t) pids[i]);
        if (task != NULL) send_signal(task, signal, info);
    }
    unlock(&pids_lock);
    return (NSUInteger) count;
}

/// Signal every guest process in `sid`'s session. Must run on the guest queue.
///
/// A command runs as its own session leader (see the `task_setsid` call where it
/// starts), and this is what still reaches a background child after its parent
/// has exited: the child has been reparented to init, so the tree walk above can
/// no longer find it.
- (NSUInteger)signalSessionOnQueue:(int)sid signal:(int)signal {
    if (sid <= 1) return 0;
    NSUInteger count = 0;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    for (int pid = 2; pid <= MAX_PID; pid++) {
        struct task *task = pid_get_task((dword_t) pid);
        if (task != NULL && task->group != NULL && task->group->sid == sid) {
            send_signal(task, signal, info);
            count++;
        }
    }
    unlock(&pids_lock);
    return count;
}

- (NSUInteger)sendSignalToProcessTreeOfPID:(int)pid signal:(int)signal {
    __block NSUInteger count = 0;
    dispatch_sync(_guestQueue, ^{
        count = [self signalProcessTreeOnQueue:pid signal:signal];
    });
    return count;
}

- (NSArray<NSNumber *> *)guestProcessTreeForExecWithID:(NSString *)execID {
    DSHGuestRun *run = dsh_running_run();
    if (run == NULL || ![run.execID isEqualToString:execID]) return @[];
    __block NSArray<NSNumber *> *result = @[];
    dispatch_sync(_guestQueue, ^{
        int pids[DSH_MAX_TREE_PIDS];
        int count = 0;
        lock(&pids_lock);
        count = dsh_collect_process_tree(run.guestPID, pids, DSH_MAX_TREE_PIDS);
        unlock(&pids_lock);
        NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:(NSUInteger) count];
        for (int i = 0; i < count; i++) [numbers addObject:@(pids[i])];
        result = numbers;
    });
    return result;
}

- (BOOL)resetGuestWithError:(NSError *_Nullable *_Nullable)error {
    // A mounted fakefs cannot be torn down safely while the kernel still
    // references it (see Docs/ISH_SANDBOX_PORT.md: "Rootfs reset must stop all
    // commands first"). In this build the kernel is booted for the life of the
    // process, so the honest answer is no. The measurement script deletes the
    // container between installs instead, which is equivalent and does not lie
    // about what happened.
    if (error) {
        *error = [NSError errorWithDomain:@"dshportc.guest" code:20
                                 userInfo:@{NSLocalizedDescriptionKey:
        @"the guest kernel cannot be reset in-process; uninstall the app or delete "
        @"the container between runs"}];
    }
    return NO;
}

#pragma mark test hooks

- (BOOL)triggerKernelDieForTesting {
    // Asynchronous by nature: the handler parks a thread forever, so the call
    // cannot wait for it to finish. What this returns is only "the trigger was
    // dispatched"; the verdict is the log line the block writes below.
    dispatch_async(_guestQueue, ^{
        // Run it on a guest task, not on the queue thread: the die handler parks
        // whichever thread calls it, and parking the serial queue would wedge
        // every later command.
        extern void dsh_trigger_die_on_guest_task(void);
        int before = __atomic_load_n(&dsh_die_handler_call_count, __ATOMIC_SEQ_CST);
        dsh_trigger_die_on_guest_task();
        usleep(300000);
        BOOL fired = __atomic_load_n(&dsh_die_handler_call_count, __ATOMIC_SEQ_CST) > before;
        [[ISHGuestLog shared] append:[NSString stringWithFormat:
            @"[guest] kernel die() test: handler fired = %@, message = \"%s\"",
            fired ? @"yes" : @"NO", dsh_die_handler_last_message]];
    });
    // The dispatch above is async; the console reads the log for the verdict.
    return YES;
}
@end
