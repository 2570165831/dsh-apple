//
//  ISHGuest.h
//  DSHPortC
//
//  The embedded Linux guest: an iSH ARM64 kernel running an Alpine rootfs
//  inside this app's process, plus a small executor on top of it.
//
//  This is deliberately not a general shell API. It boots once, runs one
//  command at a time, and reports output plus an exit code. Step 3 of the plan
//  turns this into the Node <-> Swift channel; until then the debug console is
//  the only caller, and that keeps the surface small enough to reason about.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which phase the guest boot pipeline has reached. Mirrors ISHGuestPhase in
/// the Swift bridge; keep the raw values in sync (they are written to the status
/// JSON that the host-side script polls).
typedef NS_ENUM(NSInteger, ISHGuestState) {
    ISHGuestStateIdle = 0,
    ISHGuestStateInstallingRoot,   // importing the bundled image into the container
    ISHGuestStateMounting,         // mount_root + fakefs registration
    ISHGuestStateBooting,          // PID 1, device nodes, procfs, exit hook, tty
    ISHGuestStateReady,            // booted; commands can run
    ISHGuestStateFailed,
};

/// One finished command.
@interface ISHGuestResult : NSObject
/// stdout followed by stderr, in the order the guest wrote them to each
/// stream. Kept separate below for callers that need the distinction.
@property (nonatomic, copy) NSString *output;
@property (nonatomic, copy) NSString *standardOutput;
@property (nonatomic, copy) NSString *standardError;
/// Shell-style exit code: 0-255, or 128+signal.
@property (nonatomic) int exitCode;
/// Guest PID, or -1 if the command never started.
@property (nonatomic) int pid;
/// Wall-clock seconds from handing the command to the guest to its exit.
@property (nonatomic) double duration;
/// Non-nil when the command could not be run at all (not when it ran and
/// failed: a non-zero exitCode is a normal outcome).
@property (nonatomic, copy, nullable) NSString *launchError;
/// YES when the command was killed because it exceeded the caller's timeout.
@property (nonatomic) BOOL timedOut;
@end

/// Called for each line as it arrives, on the main queue. `isStdErr`
/// distinguishes the two streams so the console can colour them.
typedef void (^ISHGuestLineBlock)(NSString *line, BOOL isStdErr);
typedef void (^ISHGuestCompletionBlock)(ISHGuestResult *result);

/// One chunk of output, exactly as the guest wrote it, with no line splitting
/// and no decoding. The Node channel forwards these bytes as they arrive; the
/// incremental UTF-8 decoder lives on the Node side so a character split across
/// two chunks survives.
typedef void (^ISHGuestChunkBlock)(NSData *data, BOOL isStdErr);

/// One command as asked for over the channel.
///
/// Kept separate from `runCommand:` on purpose: the channel needs byte-level
/// chunks, a session handle it can cancel by ID, and an argv vector that is not
/// re-quoted through a shell. Sharing the executor internals but not the entry
/// point is what keeps the debug console's line-oriented path untouched.
@interface ISHGuestExecRequest : NSObject
/// The command, already fully formed. Run as `argv` if `argv` is non-nil,
/// otherwise as `/bin/sh -c command`.
@property (nonatomic, copy) NSString *command;
/// Optional explicit argv (argv[0] included). Overrides `command` when set.
@property (nonatomic, copy, nullable) NSArray<NSString *> *argv;
/// Guest working directory. Nil or empty means "the guest's default".
@property (nonatomic, copy, nullable) NSString *workingDirectory;
/// Seconds; 0 means no timeout.
@property (nonatomic) NSTimeInterval timeout;
/// Optional stdin, written to the guest process and then closed.
@property (nonatomic, copy, nullable) NSData *stdin;
/// Extra environment entries, "K=V". Merged over the defaults.
@property (nonatomic, copy, nullable) NSArray<NSString *> *environment;
/// Maximum bytes retained for the caller. Output past this is counted and
/// dropped, and `truncated` is set. 0 means the default cap. Only consulted
/// when `retainOutput` is YES.
@property (nonatomic) NSUInteger maxOutputBytes;
/// Whether this side keeps any copy of the output at all. Default YES, which
/// is what the debug console wants.
///
/// The Node channel sets this to NO deliberately. Bounded output belongs to
/// the Node side: `@deepseek-ai/dsh-subprocess-local/output`'s
/// `OutputCollector` owns `maxBytes` and the spill file that is
/// contractually the *complete* stream. If Swift also dropped bytes, the spill
/// could no longer be complete and `truncated` would be decided by the wrong
/// layer. With this NO the bytes stream through untouched and are only
/// *counted* here, so the 10 MB `yes | head -c` case neither breaks the spill
/// promise nor grows an NSMutableData until the app is killed.
@property (nonatomic) BOOL retainOutput;
/// Caller-chosen correlation id, echoed back in the result and used by
/// `cancelExecWithID:`. Nil means the guest generates one.
@property (nonatomic, copy, nullable) NSString *execID;
@end

/// A running (or finished) exec, as the channel sees it.
@interface ISHGuestExecResult : ISHGuestResult
@property (nonatomic, copy) NSString *execID;
/// YES when output was dropped because it exceeded `maxOutputBytes`.
@property (nonatomic) BOOL truncated;
/// Bytes of output the guest produced, including any dropped tail.
@property (nonatomic) unsigned long long totalOutputBytes;
@end

@interface ISHGuest : NSObject

/// Process-wide guest. There is one kernel per process; a second instance would
/// be two kernels fighting over the same global `current`, so this is a
/// singleton rather than a factory.
@property (class, nonatomic, readonly) ISHGuest *shared;

@property (nonatomic, readonly) ISHGuestState state;
/// Human-readable detail for the current state, safe to show to a user.
@property (atomic, readonly, copy) NSString *stateDetail;
/// Where the guest's fakefs data lives in the app container.
@property (nonatomic, readonly, copy, nullable) NSString *rootPath;
/// Seconds spent booting the kernel in the most recent successful boot.
@property (nonatomic, readonly) double bootSeconds;
/// Seconds spent importing the rootfs on first launch (0 if not this launch).
@property (nonatomic, readonly) double rootfsImportSeconds;

/// Boot the guest. Idempotent: a second call while ready returns immediately,
/// and a call while booting waits on the boot in progress rather than starting
/// a second one — two kernels in one process is not recoverable.
/// Completion arrives on the main queue.
- (void)boot:(void (^)(NSError *_Nullable error))completion;

/// Run a command through /bin/sh inside the guest. Boots first if needed.
/// `timeout` of 0 means no timeout. Completion arrives on the main queue.
/// Only one command runs at a time; a second call while one is running fails
/// immediately with a launchError explaining that, rather than silently queueing
/// behind a command that might be waiting on input.
- (void)runCommand:(NSString *)command
           timeout:(NSTimeInterval)timeout
        lineBlock:(nullable ISHGuestLineBlock)lineBlock
        completion:(ISHGuestCompletionBlock)completion;

/// Run a command and stream raw output chunks as they arrive.
///
/// This is the entry point the Node channel uses. Unlike `runCommand:`, it
/// delivers bytes on `chunkBlock` while the command is still running, keeps the
/// exit status and the tail of the output correct, and can be cancelled by its
/// exec id.
///
/// `chunkBlock`, `lineBlock` and `completion` are all delivered on the main
/// queue, in that order of granularity. `chunkBlock` may be called from the
/// guest queue thread; it is the caller's job not to block it.
- (void)execRequest:(ISHGuestExecRequest *)request
         chunkBlock:(nullable ISHGuestChunkBlock)chunkBlock
          lineBlock:(nullable ISHGuestLineBlock)lineBlock
         completion:(void (^)(ISHGuestExecResult *result))completion;

/// Cancel a running exec by id. Returns NO if that exec is not the running one.
///
/// Cancellation is a two-step teardown owned by this side, not a single
/// `kill(2)`:
///
///   1. SIGTERM to every guest process in the exec's recorded process tree.
///   2. After `kills`' grace window, re-resolve those PIDs and SIGKILL only the
///      ones that are still the *same* task they were (a guest PID is reused
///      once reaped, so signalling by number alone can hit an innocent
///      process).
///
/// PID 1 is never signalled: the guest's init owns the whole filesystem
/// namespace, and killing it takes the guest down with no way back.
- (BOOL)cancelExecWithID:(NSString *)execID;

/// Resolve a bare command name against a PATH inside the guest, the way
/// `execvp` would: return the first candidate that exists, is a regular file,
/// and has an execute bit.
///
/// This is what `SubprocessRuntime.resolveExecutable` needs and why it cannot
/// be answered on the host: the guest's `/usr/bin/git` and the host's
/// `/usr/bin/git` are different files, and the host one may not exist at all.
/// Returns nil when nothing matched, which the caller must turn into
/// `SubprocessExecutableNotFoundError` rather than inventing a path.
///
/// `name` may be absolute, or a bare name to search. `pathValue` is the PATH to
/// search (colon-separated, guest paths); nil means the guest's default.
- (nullable NSString *)resolveExecutableNamed:(NSString *)name
                                    pathValue:(nullable NSString *)pathValue;

/// The guest process IDs that belong to the exec's process tree, as last
/// recorded. Used by the acceptance test to prove that termination reached the
/// children, and by the provider's diagnostics. Empty when nothing is running.
- (NSArray<NSNumber *> *)guestProcessTreeForExecWithID:(NSString *)execID;

/// Send a signal to a guest process by PID.
- (BOOL)sendSignal:(int)signal toPID:(int)pid;

/// Send a signal to every guest process in the current process tree of `pid`
/// (the descendants of a guest task), skipping PID 1.
///
/// Exposed for the acceptance test, which needs to prove a `sh -c 'sleep 100 &'`
/// child dies too, and for the provider's SIGTERM→SIGKILL escalation.
- (NSUInteger)sendSignalToProcessTreeOfPID:(int)pid signal:(int)signal;

/// Resolve a guest path the way the provider needs it: does it exist, is it a
/// directory, is it executable. Boots first if needed.
///
/// Implemented inside the kernel (stat + access) rather than by running
/// `test -x` in a shell, because a shell round trip costs milliseconds and adds
/// a process where a syscall answers the question.
- (void)resolvePath:(NSString *)path
         completion:(void (^)(NSDictionary<NSString *, id> *info))completion;

/// Bind a host directory into the guest at `guestPath` (read-write when
/// `readWrite`). Boots first if needed — the kernel must exist before a bind
/// mount can be registered.
///
/// This is the workspace-sharing primitive: after it returns, the same files
/// are visible at `guestPath` inside the guest and at `hostPath` on the host,
/// with no copying and no writeback layer.
- (void)bindMountGuestPath:(NSString *)guestPath
                  hostPath:(NSString *)hostPath
                 readWrite:(BOOL)readWrite
                completion:(void (^)(NSError *_Nullable error))completion;

/// The workspace mapping, if one is active.
@property (nonatomic, readonly, copy, nullable) NSString *boundWorkspaceGuestPath;
@property (nonatomic, readonly, copy, nullable) NSString *boundWorkspaceHostPath;

/// Deliberately trip the kernel's die() to prove the app survives it. Used by
/// the acceptance test; kept in the shipping binary because the alternative is
/// a fault-injection path nobody has exercised since it was written.
- (BOOL)triggerKernelDieForTesting;

/// Reset the guest: kill every process, unmount, and delete the imported
/// rootfs. Used by the measurement script to time a first-import.
- (BOOL)resetGuestWithError:(NSError *_Nullable *_Nullable)error;

@end

/// The app's log of what the guest did, as lines. The debug console reads this;
/// so does the diagnostics dump. Bounded, so a runaway command cannot exhaust
/// memory.
@interface ISHGuestLog : NSObject
@property (class, nonatomic, readonly) ISHGuestLog *shared;
- (void)append:(NSString *)line;
- (NSArray<NSString *> *)lines;
- (NSString *)text;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
