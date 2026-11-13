//
//  NodeRunner.swift
//  DSHPortC
//
//  Hosts nodejs-mobile inside the app process and boots the DSH Web UI on
//  loopback. Everything here is about the seam between the two: where Node's
//  files live, what its argv is, how its stdout is captured, and how the app
//  finds out when the UI is actually servable.
//
//  Design notes that came out of the spike (see logs/spike-summary.md):
//
//  * Node is jitless by default in nodejs-mobile; `typeof WebAssembly` is
//    "undefined", so the fetch polyfill in sim/ is mandatory, not optional.
//  * `cwd` starts as "/" which is read-only. The app chdirs into the sandbox
//    before Node starts, otherwise every relative path DSH touches fails.
//  * `node_start` never returns while the server runs, so it owns its thread.
//  * The launch token only exists in DSH's stdout, so stdout has to be piped
//    back into the app: dup2 a pipe over fd 1 and 2, then read it.
//

import Foundation

/// Which phase the boot pipeline has reached. Written to
/// `Documents/DSHPortC-status.json` so host-side scripts can poll it instead of
/// scraping logs.
enum BootPhase: String {
    case starting
    case preparingHome
    case copyingPayload
    case launchingNode
    case nodeRunning
    case serverListening
    case webViewLoading
    case documentLoaded
    case webViewReady
    case failed
}

struct NodeReport: Codable {
    var nodeVersion = ""
    var v8Version = ""
    var moduleVersion = ""
    var execArgv: [String] = []
    var webAssembly = ""
    var webAssemblyIsStub = false
    var webAssemblyCompiles = false
    var platform = ""
    var arch = ""
    var napiVersion = ""
    var payloadPath = ""
    var dshHome = ""
    var workspace = ""
    var jitless = false
    var childProcessBlocked = false
    var addonLoadingBlocked = false
}

struct BootStatus: Codable {
    var phase: String
    var detail: String
    var webURL: String
    var secondsSinceLaunch: Double
    var node: NodeReport
    /// Present when a phase failed; the raw message, no rewriting.
    var error: String?
    /// Node stopped or parked after a fatal exit; navigation cannot revive it.
    var runtimeFatal: Bool?
    /// First client startup error, retained for diagnostics if readiness times out.
    var clientStartupError: String?
    /// Present when the guest came up degraded (bind mount or channel failed).
    /// Separate from `error` because the web UI still works in that case.
    var guestError: String?
    /// Step 13: what the background-continuation lifecycle observed. Optional so
    /// every earlier script that reads this file keeps parsing it, and populated
    /// only once the app has actually reached a background transition or a busy
    /// line — an absent key means "not reported yet", not "nothing happened".
    var background: BackgroundReport?
    /// Step 16: what the notification bridge observed. Optional for the same
    /// reason: an earlier reader keeps parsing, and an absent key means "this
    /// build never wrote one", which is not the same as "no notification was
    /// sent" — `delivered` and `suppressed` inside it are what say that.
    var notifications: NotificationReport?
    /// Step 19: this launch's id. Same optionality rule as the two above, so a
    /// script written against an earlier step keeps parsing this file.
    var launchId: String?
    /// Step 19: the safe-mode decision, once Node has announced it on stdout.
    /// Absent means "not reported yet", not "not in safe mode".
    var safeMode: SafeModeReport?
    /// Step 19: the boot guard's view of the failure streak.
    var bootGuard: GuardReport?
}

/// What `BackgroundContinuation` saw, verbatim. Written into the same status file
/// the boot phases use, rather than a file of its own, so a host-side script has
/// ONE place to read and cannot mistake "file absent" for "feature inactive".
struct BackgroundReport: Codable {
    var busy = false
    var turn = 0
    var step = 0
    var tools = 0
    var lastOutcome = ""
    var submissions = 0
    var completions = 0
    var expirations = 0
    var holding = false
    var identifier = ""
    var capabilities: [String] = []
    var lastStateChange: String?
    /// Restates the compile-time API floor as data, so a reader never has to
    /// guess whether "no submissions" means "idle" or "this OS has no API".
    var apiAvailable = false
}

final class NodeRunner {
    static let shared = NodeRunner()

    private let launchDate = Date()
    private let queue = DispatchQueue(label: "local.dshportc.node", qos: .userInitiated)
    private let logQueue = DispatchQueue(label: "local.dshportc.log")
    private var logListeners: [(String) -> Void] = []

    private let statusStore = LockedValue(BootStatus(
        phase: BootPhase.starting.rawValue,
        detail: "",
        webURL: "",
        secondsSinceLaunch: 0,
        node: NodeReport(),
        error: nil,
        guestError: nil
    ))

    var statusSnapshot: BootStatus { statusStore.snapshot }

    /// The authenticated loopback URL, once DSH prints it.
    private(set) var authenticatedURL: URL?

    private var fileManager: FileManager { .default }

    /// Whether this launch saw a container different from the recorded one, and
    /// therefore needs the session-log rewrite. Set by
    /// `migrateStaleContainerPaths()` before the environment is built.
    private var migrateSessions = false

    // MARK: - Sandbox layout

    /// Application Support/DSH — the app-owned DSH_HOME. Created on first launch;
    /// never populated from anywhere outside the app, so no credential can leak in.
    var dshHome: URL {
        sanitized(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("DSH", isDirectory: true)
    }

    /// Documents/workspace — where the agent may read and write.
    var workspace: URL {
        sanitized(fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("workspace", isDirectory: true)
    }

    private var documentsDirectory: URL {
        sanitized(fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    /// Resolve a URL to the spelling the REST of the app will agree on.
    ///
    /// **THIS IS THE ONE PLACE THE TWO NAMESPACES ARE DECIDED, AND IT MUST USE
    /// `realpath(3)`, NOT `resolvingSymlinksInPath()`.**
    ///
    /// Foundation's `URL.resolvingSymlinksInPath()` deliberately *strips* the
    /// `/private` prefix: it answers `/var/mobile/…` for a path whose real
    /// location is `/private/var/mobile/…`, because `/var` is a documented
    /// com.apple.rootless alias and Foundation prefers the friendly spelling.
    /// `realpath(3)` — and therefore Node's `fs.realpath`, and therefore every
    /// path DSH stores — answers `/private/var/mobile/…`. Measured on this
    /// machine, both APIs, both spellings:
    ///
    ///     in: /var/tmp
    ///       URL.resolvingSymlinksInPath: /var/tmp
    ///       realpath(3):                 /private/var/tmp
    ///
    /// The app used to take the Foundation answer while publishing that path into
    /// Node's environment and into the profile, so:
    ///
    ///   * `workspace-controller.documentsDirectory` was `/var/…`, and the
    ///     controller *string-joins* `deepseek-harness/default-workspace` onto it.
    ///     That joined path became the `defaultCwd` for a new Session, and the
    ///     session header stores it verbatim.
    ///   * `dsh-workspace` canonicalises a Workspace through `fs.realpath`, so the
    ///     registry record for the SAME folder was `/private/var/…`.
    ///
    /// Two spellings of one directory is two `projectKey()` values, which is
    /// exactly what the phone showed: some sessions under `--private-var-…--`,
    /// the rest under `--var-…--`. Deduplication at launch could only paper over
    /// it, because the divergence was re-created on the next new session.
    ///
    /// Using the same `realpath` here removes the divergence at its source: the
    /// documents directory, the profile's `__WORKSPACE__`, the environment, the
    /// session `cwd` and the registry record are then all one string.
    ///
    /// Falls back to the Foundation answer only when `realpath` cannot resolve
    /// the path (it does not exist yet), and creates the directory first so that
    /// fallback is not the normal case.
    private func sanitized(_ url: URL) -> URL {
        var directory = url.standardizedFileURL
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let resolved = NodeRunner.realPath(directory.path) {
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
        return directory.resolvingSymlinksInPath()
    }

    /// `realpath(3)` for one path, or nil when it cannot be resolved.
    ///
    /// A separate function rather than an inline call so the reason it exists —
    /// agreement with Node's `fs.realpath` — is stated where the call is made.
    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    var bundleRoot: URL { Bundle.main.bundleURL }

    var payloadDirectory: URL { bundleRoot.appendingPathComponent("dsh-payload", isDirectory: true) }
    var simDirectory: URL { bundleRoot.appendingPathComponent("sim", isDirectory: true) }

    /// Task-owned DSH plugins (the guest subprocess provider among them). A
    /// folder reference in the Xcode project keeps the tree intact, so a plugin
    /// keeps its own `lib/` beside its entry module.
    var pluginsDirectory: URL { bundleRoot.appendingPathComponent("plugins", isDirectory: true) }
    static let profileBundleName = "dsh-ios-profile"
    var profileTemplateDirectory: URL { bundleRoot.appendingPathComponent("profiles/ios-sim", isDirectory: true) }

    /// The three runtime files live in `Library/Application Support/DSHPortC/`,
    /// NOT in `Documents/`.
    ///
    /// `Documents/` is user-visible in the Files app (file sharing is on, and it
    /// stays on — that is how the workspace is reachable). Everything in it is
    /// therefore something the user can see, copy and hand to another app. The
    /// status file and the boot log are noise there; the session URL file is
    /// worse than noise, because it holds a live bearer token in plaintext.
    /// `RuntimePaths` states all of that in one place; these three lines are the
    /// only seam between it and this class.
    var statusFileURL: URL { RuntimePaths.statusFile }
    var logFileURL: URL { RuntimePaths.logFile }

    /// The authenticated URL, kept out of the log on purpose.
    ///
    /// DSH mints a fresh launch token per launch and puts it in the one URL it
    /// prints. The web view needs that URL, and so does anything that wants to
    /// talk to the server the way the UI does. Keeping it here rather than in the
    /// log means the log can be pasted into a report without leaking a live
    /// token, while the app still has what it needs. Since step 17 it also sits
    /// outside `Documents/`, so the Files app cannot surface it. The file dies
    /// with the token on the next launch.
    var sessionURLFileURL: URL { RuntimePaths.sessionURLFile }

    // MARK: - Log plumbing

    func onLog(_ listener: @escaping (String) -> Void) {
        logQueue.sync { logListeners.append(listener) }
    }

    func existingLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }

    /// Internal rather than private so a launch-gated probe can put its own line in
    /// the boot log — `ContentView`'s hold-the-ready-signal switch is the only
    /// caller. Nothing here is a credential: `emit` redacts on the way out.
    func emit(_ line: String) {
        logQueue.async {
            // Redact the launch token everywhere it could be displayed. The app
            // needs the URL, but the token must not end up in a screenshot or a
            // pasted log line.
            let safe = NodeRunner.redact(line)
            try? BootLogFile.append(Data((safe + "\n").utf8), to: self.logFileURL)
            for listener in self.logListeners { listener(safe) }
        }
    }

    /// Replace `token=...` with `token=<redacted>`, and the guest channel's own
    /// bearer token wherever it appears.
    ///
    /// Two mechanisms on purpose. The regex catches the launch URL DSH prints;
    /// `ISHGuestChannel.redact` catches this process's guest token, which is not
    /// in a `token=` parameter anywhere and whose exact spelling only that
    /// object knows. Neither is a substitute for not logging a credential in the
    /// first place — they are the belt to that braces.
    static func redact(_ text: String) -> String {
        let withoutLaunchToken = text.replacingOccurrences(
            of: "token=[A-Za-z0-9._~+/=-]+",
            with: "token=<redacted>",
            options: .regularExpression
        )
        return ISHGuestChannel.shared.redact(withoutLaunchToken)
    }

    private func writeStatus(_ mutate: @escaping (inout BootStatus) -> Void) {
        queue.async {
            self.persistStatus(mutate)
        }
    }

    /// Caller is on the boot queue. Copy under the lock, then write without it.
    private func persistStatus(_ mutate: (inout BootStatus) -> Void) {
        let snapshot = statusStore.update { status in
            mutate(&status)
            status.secondsSinceLaunch = Date().timeIntervalSince(launchDate)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: statusFileURL, options: .atomic)
        }
    }

    // MARK: - Boot

    func begin() {
        // Before anything is written: take the legacy runtime files out of
        // `Documents/`. A container carried over from an older build still has
        // them there, and one of them is the plaintext session URL. This runs
        // first, and every launch, so a user who updates the app does not keep
        // the token on display in the Files app until something else happens to
        // touch that directory.
        let legacyLeftovers = RuntimePaths.removeLegacyDocumentFiles()
        for leftover in legacyLeftovers {
            NSLog("dshportc: could not remove legacy file from Documents: %@", leftover)
        }

        // STEP 19, and the order of these two calls is the whole crash-safety
        // argument (see `ResetRunner`): an interrupted reset is finished FIRST, so
        // the app is in one known state before anything else looks at the
        // filesystem; a fresh reset is executed SECOND and still before
        // `prepareFilesystem()`, so the directories it moves away are re-created
        // afterwards by that method rather than by this one.
        //
        // A reset that did not finish stops the launch here: DSH started on a
        // container where some entries moved and some did not is the mix of old
        // and new data the reset exists to prevent. The records stay on disk and
        // the next launch carries on from them.
        var resetFailure: String?
        var resetNotes: [String] = []
        if let resumed = ResetRunner.finishInterruptedIfAny() {
            resetNotes.append(resumed.note)
            if !resumed.ok { resetFailure = resumed.reason }
        }
        // A half-finished earlier reset holds any new request back, rather than
        // stacking a second reset on top of it.
        if resetFailure == nil, let applied = ResetRunner.applyPendingIfAny() {
            resetNotes.append(applied.note)
            if !applied.ok { resetFailure = applied.reason }
        }

        RuntimePaths.finishReset(success: resetFailure == nil)
        BootGuard.flushBackgroundMarker()
        try? FileManager.default.removeItem(at: logFileURL)
        emit("dshportc: boot pipeline started")
        if !legacyLeftovers.isEmpty {
            emit("dshportc: WARNING legacy files still in Documents: " + legacyLeftovers.joined(separator: ", "))
        }
        writeStatus {
            $0.detail = "boot pipeline started"
            $0.launchId = BootGuard.launchId
            $0.bootGuard = BootGuard.report()
        }
        emit("dshportc: launch id " + BootGuard.launchId)
        for note in resetNotes { emit("dshportc: " + note) }
        // Step 19B's device evidence for the one delete in this step. Same function
        // the panel's confirmed button calls, so what this measures and what a user
        // gets cannot differ. Nothing else in the app calls it.
        if UserDefaults.standard.integer(forKey: "DSHPortEStep19PurgeStaging") == 1 {
            let before = ResetRunner.stagingSize()
            emit("dshportc: staging holds \(before) bytes before the purge")
            emit("dshportc: " + ResetRunner.purgeStaging())
            emit("dshportc: staging holds \(ResetRunner.stagingSize()) bytes after the purge")
        }
        if let message = resetFailure {
            // Reads and writes stay under reset-staging/launch-<id>, including
            // the failure screen's diagnostics. Do not recreate moved paths.
            // No watchdog and no guest: nothing is going to start.
            emit("dshportc: FAILED \(message)")
            writeStatus {
                $0.phase = BootPhase.failed.rawValue
                $0.detail = message
                $0.error = message
            }
            BootGuard.cancelWatchdog()
            BootGuard.recordOutcome(kind: "failure", reason: message, phase: BootPhase.failed.rawValue)
            return
        }

        // Step 19's watchdog. Started here rather than after `node_start` because
        // a launch can also hang before then (the guest's first-command wait), and
        // "nothing has happened for a minute" is the same problem wherever it
        // happens. `noteWebViewReady` and `noteFailure` both cancel it.
        BootGuard.startWatchdog {
            NodeRunner.shared.noteReadinessTimeout()
        }

        // Bring the guest up first when it is asked for: the channel's URL and
        // token are published into `makeEnvironment()`, so Node must not start
        // until the listener is bound. When the guest is not enabled the
        // coordinator returns immediately and this is the step-1 pipeline.
        GuestWorkspaceCoordinator.shared.startIfEnabled { _ in
            self.queue.async { self.prepareAndLaunch() }
        }
    }

    /// Record a guest-phase line in the boot log and the status detail.
    func noteGuestPhasing(_ message: String) {
        emit("dshportc: " + message)
        writeStatus { $0.detail = message }
    }

    /// Record a non-fatal guest problem. The web UI still comes up; this is what
    /// makes the reason visible instead of surfacing as a failing tool call much
    /// later.
    func noteGuestFailure(_ message: String) {
        emit("dshportc: GUEST DEGRADED " + message)
        writeStatus {
            $0.detail = message
            $0.guestError = message
        }
    }

    private func prepareAndLaunch() {
        // Safe mode has already died twice: a crash that takes the process with it,
        // or this launch would too. Stop here so the failure screen's buttons can be
        // reached at all, and let the next launch start the count over. Node never
        // runs here, so the request stays on disk: seeing it means this is that next
        // launch, and Node will consume it.
        let guardReport = BootGuard.report()
        let retryRequested = FileManager.default.fileExists(atPath: RuntimePaths.bootRequestFile.path)
        if guardReport.safeMode, guardReport.safeModeFailures >= 2, !retryRequested {
            let message = "连续多次启动失败，这次没有继续启动。可以看日志、导出诊断包或重置；重新打开 App 会再试一次。"
            _ = BootGuard.request("clear-guard")
            BootGuard.cancelWatchdog()
            emit("dshportc: FAILED \(message)")
            writeStatus {
                $0.phase = BootPhase.failed.rawValue
                $0.detail = message
                $0.error = message
            }
            return
        }
        do {
            writeStatus { $0.phase = BootPhase.preparingHome.rawValue }
            try prepareFilesystem()
            writeStatus { $0.phase = BootPhase.launchingNode.rawValue }
            let argv = try makeArgv()
            // STEP 21's failure-path check, and it is gated so a normal launch
            // cannot reach it. The task asks for the log entry to appear only when
            // the launch has gone wrong, and there has to be a way to make a launch
            // go wrong on purpose to prove that: waiting for a real failure is not
            // a test. `-DSHPortEBootFailFast 1` fails here, after the filesystem is
            // ready, which is the same place a real failure would surface.
            if UserDefaults.standard.integer(forKey: "DSHPortEBootFailFast") == 1 {
                throw BootError.missingResource("DSHPortEBootFailFast: simulated launch failure")
            }
            let environment = makeEnvironment()
            writeStatus { $0.detail = "node argv: " + argv.joined(separator: " ") }
            emit("dshportc: node argv " + NodeRunner.redact(argv.joined(separator: " ")))
            startNode(argv: argv, environment: environment)
        } catch {
            let message = "\(error)"
            emit("dshportc: FAILED \(message)")
            writeStatus {
                $0.phase = BootPhase.failed.rawValue
                $0.detail = message
                $0.error = message
            }
            // Step 19, failure source C: a launch that threw inside
            // `prepareAndLaunch` — a missing `payload/`, a broken profile, the
            // fail-fast switch. Recorded here so the failure screen names the
            // real reason instead of "process ended". The watchdog goes first: left
            // running it would replace this reason on screen a minute later.
            BootGuard.cancelWatchdog()
            BootGuard.recordOutcome(kind: "failure", reason: message, phase: BootPhase.failed.rawValue)
        }
    }

    /// Build the sandbox: DSH_HOME, the workspace, and the profile directory.
    ///
    /// The profile is app-owned. It is copied from the bundle on every launch so
    /// an app update always ships a profile that matches the payload it came
    /// with; anything DSH wrote into DSH_HOME's own state directories is left
    /// alone.
    /// An App's data container UUID is not stable: installing over an existing
    /// copy reassigns it, carries DSH_HOME into the new container and deletes the
    /// old one (measured on the simulator too — `simctl install` over an existing
    /// app does exactly what `devicectl` does on a phone). Two things in DSH_HOME
    /// then still name the dead container:
    ///
    ///  * `storages/**/*.json` holds the absolute workspace path. DSH walks it
    ///    with a recursive mkdir and the sandbox answers EPERM for another app's
    ///    container root ("failed to ensure project directory ... EPERM").
    ///  * every session log records the project path in its header, inside a
    ///    Zstandard frame. A log whose header disagrees with the folder it sits
    ///    in is "corrupt" to DSH, and that one error stops the whole workspace
    ///    registry from loading — which leaves the session and workspace
    ///    controllers pending, and the user's history gone.
    ///
    /// **Both rewrites happen in Node** (`sim/session-migrate.mjs`), for one
    /// reason: they are the same rule. The path a session header carries and the
    /// path a storage file carries are both "the workspace under some app
    /// container", and answering them differently is how the first version of
    /// this step shipped a storage rewrite that silently did nothing on the
    /// simulator — its regex only knew the device spelling
    /// (`/var/mobile/Containers/...`) and the simulator's is
    /// (`/Users/.../CoreSimulator/Devices/<udid>/data/Containers/...`). Node has
    /// `node:zlib` with Zstandard here (measured), so it can do the frame work
    /// too, and the rules stay in one place.
    ///
    /// What stays here: deciding that a migration is needed at all, and publishing
    /// the container so the module knows what "current" means. `DSH/.container-root`
    /// records the container this launch saw.
    private func migrateStaleContainerPaths() {
        let current = workspace.deletingLastPathComponent().deletingLastPathComponent().path
        let marker = dshHome.appendingPathComponent(".container-root")
        let stored = try? String(contentsOf: marker, encoding: .utf8)
        // The module runs on every launch, not only when the container moved: a
        // session quarantined by an earlier build has nothing to do with whether
        // THIS launch moved, and step 4B/5 left real ones behind. A `.swept` marker
        // inside each quarantine stamp folder keeps that a no-op per folder.
        migrateSessions = true
        if stored == current { return }
        try? current.write(to: marker, atomically: true, encoding: .utf8)
        NSLog("dshportc: container changed from %@ to %@; Node will migrate DSH_HOME",
              stored ?? "(none)", current)
        noteGuestPhasing("container changed: Node migrates storage paths and session headers")
    }

    /// Two workspace records for one folder make DSH refuse the whole registry
    /// ("workspace domain is inconsistent: path ... is claimed by both workspace A
    /// and workspace B"), which leaves the session and workspace controllers
    /// pending and every prompt failing. On a device the same folder has two
    /// spellings, `/var/mobile/...` and `/private/var/mobile/...` (the second is
    /// the real path behind the first), and DSH can end up holding one record for
    /// each: once the user picks a folder the picker spelled one way that the
    /// registry already knew the other way. The container migration above
    /// rewrites both to one spelling, which turns the pair into a collision.
    ///
    /// **THE DIRECTION OF THE FOLD IS THE BUG STEP 9 FIXED.** This used to
    /// normalise `/private/var` to `/var`, which is the opposite of what
    /// `dsh-workspace` produces: it canonicalises every workspace path and every
    /// session cwd through `fs.realpath` (`realpathNormalize`), and Node answers
    /// `/private/var/...`. The launch-time repair therefore rewrote the registry to
    /// one spelling, and the running DSH immediately disagreed with it — the
    /// dropdown then listed the same folder twice and selecting the `/var/...` row
    /// failed as `session/workspace-attach-failed`, because `attachSession`
    /// realpaths the new session's cwd, gets `/private/var/...`, and compares it to
    /// the stored `/var/...` path.
    ///
    /// So the fold now runs INTO `realpath`, via the same `realPath` this class
    /// already uses to decide the spelling it publishes. Runs every launch, before
    /// Node: canonicalise every record's path, then merge records with the same
    /// path into the oldest one (union of session ids, first title kept) and fix
    /// the lists that name them. Touches only `storages/workspace.json`; a no-op
    /// when there is nothing to change.
    private func repairWorkspaceRegistry() {
        let registry = dshHome.appendingPathComponent("storages/workspace.json")
        guard let data = try? Data(contentsOf: registry),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var tables = root["tables"] as? [String: Any],
              var workspaces = tables["workspaces"] as? [String: Any] else { return }
        // The A/B switch. `DSHPORTE_REGISTRY_FOLD=friendly` restores the pre-step-9
        // behaviour (`/private/var` -> `/var`), which is what makes the report's
        // "before" column a measurement of this build rather than a memory of an
        // older one. Nothing in normal operation sets it; the acceptance harness
        // does, and the report says which run is which.
        let foldToFriendly = (ProcessInfo.processInfo.environment["DSHPORTE_REGISTRY_FOLD"] ?? "").lowercased() == "friendly"
        /// The canonical spelling: `realpath(3)`, exactly what `dsh-workspace`
        /// compares against. A path that cannot be resolved (the folder is gone)
        /// still gets the `/var` -> `/private/var` prefix fold, so a dead record is
        /// not left in the spelling the runtime will never produce.
        func spelled(_ path: String) -> String {
            if foldToFriendly {
                return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
            }
            let folded = path == "/var" ? "/private/var"
                : path.hasPrefix("/var/") ? "/private" + path
                : path
            return NodeRunner.realPath(folded) ?? folded
        }
        var changed = false
        // Oldest first, ties broken by id so the choice is stable.
        let ordered = workspaces.keys.sorted { a, b in
            let ca = ((workspaces[a] as? [String: Any])?["createdAt"] as? String) ?? ""
            let cb = ((workspaces[b] as? [String: Any])?["createdAt"] as? String) ?? ""
            return ca == cb ? a < b : ca < cb
        }
        var keeperForPath: [String: String] = [:]
        var dropped: [String: String] = [:]   // dropped id -> keeper id
        for id in ordered {
            guard var entry = workspaces[id] as? [String: Any], let raw = entry["path"] as? String else { continue }
            let path = spelled(raw)
            if path != raw { entry["path"] = path; workspaces[id] = entry; changed = true }
            if let keeper = keeperForPath[path] {
                var kept = workspaces[keeper] as? [String: Any] ?? [:]
                var ids = kept["sessionIds"] as? [String] ?? []
                for sid in (entry["sessionIds"] as? [String] ?? []) where !ids.contains(sid) { ids.append(sid) }
                kept["sessionIds"] = ids
                workspaces[keeper] = kept
                workspaces.removeValue(forKey: id)
                dropped[id] = keeper
                changed = true
            } else {
                keeperForPath[path] = id
            }
        }
        guard changed else { return }
        tables["workspaces"] = workspaces
        root["tables"] = tables
        if var global = root["global"] as? [String: Any] {
            if let listed = global["workspaceIds"] as? [String] {
                var seen = Set<String>()
                global["workspaceIds"] = listed.map { dropped[$0] ?? $0 }.filter { seen.insert($0).inserted }
            }
            if let current = global["defaultWorkspaceId"] as? String, let keeper = dropped[current] {
                global["defaultWorkspaceId"] = keeper
            }
            root["global"] = global
        }
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
           (try? out.write(to: registry, options: .atomic)) != nil {
            NSLog("dshportc: workspace registry repaired; merged %d duplicate record(s)", dropped.count)
            noteGuestPhasing("workspace registry repaired: merged \(dropped.count) duplicate record(s)")
        }
    }

    private func prepareFilesystem() throws {
        try fileManager.createDirectory(at: dshHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        migrateStaleContainerPaths()
        repairWorkspaceRegistry()

        guard fileManager.fileExists(atPath: payloadDirectory.path) else {
            throw BootError.missingResource("payload/")
        }
        guard fileManager.fileExists(atPath: simDirectory.path) else {
            throw BootError.missingResource("sim/")
        }
        // The profile names three providers out of here. A missing tree would
        // otherwise surface as a loader "entry not found" for a row the profile
        // patch cannot silently drop.
        guard fileManager.fileExists(atPath: pluginsDirectory.path) else {
            throw BootError.missingResource("plugins/")
        }
        guard fileManager.fileExists(atPath: profileTemplateDirectory.path) else {
            throw BootError.missingResource("profiles/ios-sim/")
        }

        let launcher = payloadDirectory
            .appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        guard fileManager.fileExists(atPath: launcher.path) else {
            throw BootError.missingResource("payload/node_modules/@deepseek-ai/dsh/lib/bin.js")
        }

        let profileDirectory = dshHome.appendingPathComponent("profiles/ios-sim", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        for file in ["cordis.yml", "package.json", "pnpm-workspace.yaml"] {
            let source = profileTemplateDirectory.appendingPathComponent(file)
            let destination = profileDirectory.appendingPathComponent(file)
            if fileManager.fileExists(atPath: destination.path) { continue }
            try fileManager.copyItem(at: source, to: destination)
        }

        // The app's own layer is a bundle, rewritten every launch: it carries absolute
        // paths into this app container, which change on reinstall. It stays out of
        // cordis.patch.yml because that file is where Settings saves, and rewriting it
        // threw away every saved provider on the next launch.
        let bundleDirectory = profileDirectory.appendingPathComponent(
            "node_modules/\(NodeRunner.profileBundleName)", isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let patchSource = profileTemplateDirectory.appendingPathComponent("cordis.patch.yml")
        let rendered = try renderProfilePatch(at: patchSource)
        try rendered.write(
            to: bundleDirectory.appendingPathComponent("cordis.patch.yml"),
            atomically: true,
            encoding: .utf8
        )
        try #"{ "name": "\#(NodeRunner.profileBundleName)", "version": "0.0.0", "private": true, "dsh": { "bundle": { "patch": "./cordis.patch.yml" } } }"#
            .write(
                to: bundleDirectory.appendingPathComponent("package.json"),
                atomically: true,
                encoding: .utf8
            )

        // A profile from before the bundle: its manifest doesn't list the bundle, and
        // its cordis.patch.yml is a rendered copy of the app's layer, which would keep
        // overriding the bundle with this launch's stale paths.
        let manifest = profileDirectory.appendingPathComponent("package.json")
        if try !String(contentsOf: manifest, encoding: .utf8).contains(NodeRunner.profileBundleName) {
            try fileManager.removeItem(at: manifest)
            try fileManager.copyItem(at: profileTemplateDirectory.appendingPathComponent("package.json"), to: manifest)
        }
        let userPatch = profileDirectory.appendingPathComponent("cordis.patch.yml")
        // STEP 19: while safe mode has the user layer parked, do not touch it.
        //
        // The tidy-up below normally leaves `[]` alone, but two of its cases do
        // write the file: a zero-byte file, and a file that was deleted and is
        // about to be re-created. During a safe-mode session the file in place is
        // `[]` BY DESIGN (`safe-mode.mjs` wrote it), and the user's real layer is
        // beside it as `.safe-mode-parked`. Writing over the `[]` in those two
        // cases would either lose an edit made during the session or leave the
        // next launch's restore putting the parked copy on top of a file it did
        // not expect. So the whole branch is skipped while the parked copy exists;
        // `restoreUserPatch()` on the next normal launch puts the original back.
        let parkedUserPatch = RuntimePaths.parkedUserPatchFile(profileDirectory)
        let safeModeHasTheLayer = fileManager.fileExists(atPath: parkedUserPatch.path)
        if safeModeHasTheLayer {
            emit("dshportc: user layer is parked by safe mode; leaving cordis.patch.yml alone")
        }
        let userText = (try? String(contentsOf: userPatch, encoding: .utf8)) ?? ""
        if !safeModeHasTheLayer, userText.isEmpty || userText.contains("dsh-sandbox-ios/index.mjs") {
            if !userText.isEmpty {
                let saved = profileDirectory.appendingPathComponent("cordis.patch.yml.before-bundle")
                try? fileManager.removeItem(at: saved)
                try fileManager.moveItem(at: userPatch, to: saved)
                emit("dshportc: moved the old rendered profile patch to \(saved.lastPathComponent)")
            }
            try "[]\n".write(to: userPatch, atomically: true, encoding: .utf8)
        }
        emit("dshportc: dsh home ready at \(dshHome.path)")
        emit("dshportc: workspace \(workspace.path)")
    }

    /// Substitute `__PAYLOAD__`, `__SIM__`, `__PLUGINS__`, `__WORKSPACE__`,
    /// `__DSH_HOME__` placeholders.
    ///
    /// Done here rather than with `!!js process.env...` inside the YAML so the
    /// profile stays readable and the values are visible in the log when
    /// something goes wrong.
    private func renderProfilePatch(at url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        let substitutions = [
            "__PAYLOAD__": payloadDirectory.path,
            "__SIM__": simDirectory.path,
            "__PLUGINS__": pluginsDirectory.path,
            "__WORKSPACE__": workspace.path,
            "__DSH_HOME__": dshHome.path,
        ]
        for (placeholder, value) in substitutions {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        return text
    }

    private func makeArgv() throws -> [String] {
        let preload = simDirectory.appendingPathComponent("ios-sim-preload.cjs")
        let entry = simDirectory.appendingPathComponent("ios-app-entry.mjs")
        for required in [preload, entry] where !fileManager.fileExists(atPath: required.path) {
            throw BootError.missingResource("sim/" + required.lastPathComponent)
        }
        // `--expose-internals` is not optional: the patched `dsh-app-boot`
        // reaches Node internals through a plain `require()` only when the flag
        // is present, and `node-addon-require-builtin` has no iOS build.
        return [
            "node",
            "--expose-internals",
            "--require", preload.path,
            entry.path,
            "--profile", "ios-sim",
            "--no-open",
            "--host", "127.0.0.1",
            // Port 0: let the OS pick a free one. The real port arrives in the
            // URL DSH prints, which the app parses below.
            "--port", "0",
        ]
    }

    /// Re-publish launch arguments the Node side needs as environment variables.
    ///
    /// `simctl launch -DKey value` writes into the ARGUMENT DOMAIN, which Swift
    /// reads through `UserDefaults` and Node cannot see at all. The
    /// `SIMCTL_CHILD_*` alternative is unreliable: the simulator keeps the FIRST
    /// set of those it saw until the whole device shuts down (REPORT-5 records this
    /// from the ancestor-EPERM test), and this step hit it four times — a flag
    /// added on a later launch of the same boot simply never arrives, which looks
    /// exactly like a test that silently did nothing.
    ///
    /// So the harness passes launch arguments, Swift reads them, and this method
    /// puts the ones the Node side owns into `process.env` for that launch. The
    /// value is a plain string; nothing here is a credential.
    private func forwardTestFlags(into environment: inout [String: String]) {
        let defaults = UserDefaults.standard
        let forwarded = [
            "DSHPORTE_SESSION_LIST_ACCEPTANCE": "DSHPortCTestSessionListAcceptance",
            "DSHPORTE_EXPECT_SESSION": "DSHPortCTestSessionId",
            "DSHPORTE_TZ_PROBE": "DSHPortCTestTzProbe",
            "DSHPORTE_TZ_API_PROBE": "DSHPortCTestTzApiProbe",
            "DSHPORTE_STEP6_PROBE": "DSHPortCTestStep6Probe",
            // The "and it can still take a turn" half of the first criterion. The
            // sidebar cannot be clicked at 402 px (its rows never enter the DOM),
            // so the turn is driven through the controller the UI's send button
            // reaches, against the same migrated log.
            "DSHPORTE_SESSION_CONTINUE": "DSHPortCTestContinueSession",
            "DSHPORTE_CONTINUE_PROMPT": "DSHPortCTestContinuePrompt",
            // Step 7's functional acceptance: the four model-facing path/tool
            // problems. Runs INSTEAD of DSH, mounts the real profile, and drives
            // the real `ctx.fs` / `ctx.subprocess` / tools.
            "DSHPORTE_STEP7_ACCEPTANCE": "DSHPortCTestStep7Acceptance",
            // The A/B switch for the ripgrep respell. Set to `0` to reproduce the
            // pre-fix `ripgrep launch failed`, which is how the report's "before"
            // column is produced rather than described.
            "DSHPORTE_RG_RESPELL": "DSHPortCTestRgRespell",
            // Step 8's functional acceptance: the "write → bash deletes → write"
            // cycle. Same shape as step 7's gate — runs instead of DSH, mounts the
            // real profile, and reads the provider guard, the policy wiring and the
            // assembled system prompt.
            "DSHPORTE_STEP8_ACCEPTANCE": "DSHPortCTestStep8Acceptance",
            // The two files that criterion compares against. `prompts/` and `mock/`
            // are host-side test material and are deliberately NOT bundle resources,
            // so the runner copies them into the container's Documents directory and
            // passes the resulting paths here. Without them the criterion fails
            // rather than passing on a guessed bundle path.
            "DSHPORTE_PROMPT_FILE": "DSHPortCTestStep8PromptFile",
            "DSHPORTE_MOCK_REPLIES": "DSHPortCTestStep8MockReplies",
            // The control for step 8's prompt criterion: `0` removes the recovery
            // sentence from the assembled prompt, so the same build can be compared
            // against itself instead of against a remembered "before".
            "DSHPORTE_RECOVERY_NOTE": "DSHPortCTestStep8Note",
            // Step 9's functional acceptance: one canonical path spelling. The
            // duplicate dropdown rows and the unselectable workspace record are both
            // about the `/var` vs `/private/var` fold, and the criterion has to drive
            // a real `sessionController.prompt` to see the failure, so it mounts the
            // real profile like steps 7 and 8.
            "DSHPORTE_STEP9_ACCEPTANCE": "DSHPortCTestStep9Acceptance",
            // Step 9's A/B switch: `friendly` restores the pre-fix fold direction
            // (`/private/var` -> `/var`) in BOTH the Swift repair and the Node
            // migration, so the report's "before" column is measured on this build.
            "DSHPORTE_REGISTRY_FOLD": "DSHPortCTestPathFold",
            "DSHPORTE_PATH_FOLD": "DSHPortCTestPathFold",
            // Step 24: what the guest's Node, npm and Python can actually do.
            // Runs INSTEAD of DSH for that launch: every criterion is a real
            // command in the guest through the shipped `ctx.subprocess` provider,
            // and a web UI in the same process would put its own work into the
            // CPU timings this step has to report.
            "DSHPORTE_STEP24_ACCEPTANCE": "DSHPortCTestStep24Acceptance",
            // Step 24's four knobs. They are launch arguments and NOT
            // `SIMCTL_CHILD_*` variables, for the reason documented above: the
            // simulator keeps the first `SIMCTL_CHILD_*` set it saw until the whole
            // device shuts down, so a value added on a later launch of the same boot
            // never arrives. Measured on this step: `DSHPORTE_STEP24_ONLY=isolate`
            // was set on the command line and the module still saw an empty segment
            // list, because the device had been booted hours earlier by other work.
            //
            //   only        which segments to run (comma separated)
            //   isolateCase one isolate step by name, so a wedge cannot shadow the
            //               next one
            //   fixtures    the guest path of the staged fixture tree
            //   mockUrl     the local mock's URL for the https arm
            "DSHPORTE_STEP24_ONLY": "DSHPortCTestStep24Only",
            "DSHPORTE_STEP24_ISOLATE_CASE": "DSHPortCTestStep24IsolateCase",
            "DSHPORTE_STEP24_FIXTURES": "DSHPortCTestStep24Fixtures",
            "DSHPORTE_STEP24_MOCK_URL": "DSHPortCTestStep24MockUrl",
            // The A/B control for the capability text: `0` removes the
            // section, so the assembled prompt can be compared with and
            // without it on ONE build — the same shape as
            // `DSHPORTE_RECOVERY_NOTE` in step 8.
            "DSHPORTE_GUEST_RUNTIME_NOTE": "DSHPortCTestStep24Note",
            // Step 19B: create a session and take one turn in the composition this
            // launch is running. Launched with a `--patch` overlay it measures safe
            // mode; launched without one it measures the normal composition, which
            // is what makes the two comparable on ONE build.
            "DSHPORTE_STEP19_SAFE_PROBE": "DSHPortEStep19SafeProbe",
            "DSHPORTE_STEP19_PROMPT": "DSHPortEStep19Prompt",
            // Where the probe writes its verdict. Documents, like every other
            // probe file: a host script copies it out of the container.
            "DSHPORTE_STEP19_PROBE_OUT": "DSHPortEStep19ProbeOut",
            // Step 19B diagnostic: what the profile's model route resolved to. Only
            // read when set, and only set by the acceptance script.
            "DSHPORTE_STEP19_DUMP_CONFIG": "DSHPortEStep19DumpConfig",
            // Step 19B: run `ResetRunner.purgeStaging()` once at boot, so the
            // clearance button's own code path has device evidence. Gated on a
            // launch argument; the panel's confirmed button is the only other
            // caller, and a normal launch never passes this.
            "DSHPORTE_STEP19_PURGE_STAGING": "DSHPortEStep19PurgeStaging",
            // Step 19B: run the step-19 tests under the phone's own Node 22 through
            // the shipped `ctx.subprocess`, and the guest directory to run them in.
            "DSHPORTE_STEP19_GUEST_TESTS": "DSHPortEStep19GuestTests",
            "DSHPORTE_STEP19_GUEST_DIR": "DSHPortEStep19GuestDir",
        ]
        for (variable, key) in forwarded {
            if environment[variable] != nil { continue }
            if let value = defaults.string(forKey: key), !value.isEmpty {
                environment[variable] = value
            }
        }
    }

    private func makeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = dshHome.path
        environment["HOME"] = dshHome.deletingLastPathComponent().path
        environment["TMPDIR"] = NSTemporaryDirectory()
        environment["DSH_IOS_WORKSPACE"] = workspace.path
        environment["IOS_SIM_DSH_INSTALL"] = payloadDirectory.path
        environment["IOS_SIM_WORKSPACE"] = workspace.path
        environment["IOS_SIM_SANDBOX"] = workspace.path
        environment["IOS_SIM_LOG"] = dshHome.appendingPathComponent("events.jsonl").path
        // The device's zone and its DST transitions, for the ICU-less `Intl`
        // substitute. `Date` already reads the platform's localtime (measured:
        // GMT+1100 AEDT inside the simulator), but a named IANA zone needs rules
        // an ICU-less build has nowhere to look up, so they are handed over here.
        // See DeviceTimeZone.swift and sim/intl-shim.cjs.
        environment["DSHPORTE_DEVICE_TZ"] = DeviceTimeZone.environmentValue()
        // Step 19: where the boot guard's files live, and which launch this is.
        // Present only when they can be true — the module does nothing when any of
        // the three is absent, which is what keeps a desktop test harness that
        // imports the same entry from touching anything.
        environment["DSHPORTE_BOOT_GUARD"] = "1"
        environment["DSHPORTE_BOOT_DIR"] = RuntimePaths.bootDirectory.path
        environment["DSHPORTE_BOOT_LAUNCH_ID"] = BootGuard.launchId
        // Where the reset planner's root is. The module validates it and throws
        // when it is not a plausible container, and the caller catches that.
        environment["DSHPORTE_CONTAINER_ROOT"] = ResetRunner.containerRoot.path
        forwardTestFlags(into: &environment)
        // Where the session logs' stale container paths get rewritten. `Date` and
        // `Intl` cannot do it: the header is inside a Zstandard frame and has to be
        // re-encoded, which node:zlib can do (measured: zstdCompressSync present).
        // Empty when nothing moved, in which case the module does nothing.
        if migrateSessions {
            environment["DSHPORTE_SESSION_MIGRATE"] = workspace
                .deletingLastPathComponent().deletingLastPathComponent().path
        }
        // The mock model server runs on the host and is reached over the shared
        // simulator loopback. This is a literal placeholder, not a credential:
        // the mock accepts any non-empty bearer token.
        environment["DSHPORTC_MOCK_API_KEY"] = "mock-placeholder-not-a-credential"
        // Step 13: which port the mock answers on. Passed as a launch argument
        // (`-DSHPortCMockPort`) rather than `SIMCTL_CHILD_*`, for the reason
        // recorded in `forwardTestFlags`.
        //
        // STEP 21 CHANGED WHAT "UNSET" MEANS, and this is the whole fix for the
        // default-model item. The variable used to be set on EVERY launch — the
        // profile defaulted it to 19700 — and the profile's `agent-default-model`
        // keyed the choice of route on it. So a normal launch (`simctl launch`
        // with no arguments, or a tap on the home screen) set the variable, the
        // profile therefore selected `local-mock`, and the composer opened on a
        // test double whose server was not running.
        //
        // The variable is now set ONLY when a launch argument names a port, which
        // is what every acceptance script and XCUITest does and what no normal
        // launch does. `profiles/ios-sim/cordis.patch.yml` reads exactly this to
        // decide whether the mock route exists at all and what the default model
        // is; its comment records the three states.
        let mockPort = UserDefaults.standard.string(forKey: "DSHPortCMockPort") ?? ""
        if !mockPort.isEmpty {
            environment["DSHPORTC_MOCK_PORT"] = mockPort
        }
        // A real deployment's model route, passed through untouched. Not set
        // anywhere in this repository: a normal launch leaves both unset, which is
        // the "no model configured" state the profile's comment describes.
        for (variable, key) in [
            "DSH_PORTE_DEFAULT_PROVIDER": "DSHPortEDefaultProvider",
            "DSH_PORTE_DEFAULT_MODEL": "DSHPortEDefaultModel",
            "DSH_PORTE_DEFAULT_EFFORT": "DSHPortEDefaultEffort",
        ] {
            if environment[variable] != nil { continue }
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
                environment[variable] = value
            }
        }
        // Reduce V8's appetite on a phone. `--jitless` is already the default in
        // nodejs-mobile; the heap cap keeps a runaway session from being killed.
        environment["NODE_OPTIONS"] = ""

        // The guest channel, when this launch brought one up. Both values are
        // per-launch and per-process: the token is minted in `ISHGuestChannel`
        // and lives only in this environment block and that object.
        //
        // The URL and port are safe to log; the token is not, and `emit` runs
        // every line through `redact` so it cannot leak by accident.
        let channel = ISHGuestChannel.shared
        if channel.state == .listening, channel.port > 0 {
            let url = "http://127.0.0.1:\(channel.port)"
            environment["DSH_GUEST_CHANNEL_URL"] = url
            environment["DSH_GUEST_CHANNEL_PORT"] = String(channel.port)
            if let token = channel.token {
                environment["DSH_GUEST_CHANNEL_TOKEN"] = token
            }
        }
        // Where the guest sees the workspace, when a bind mount succeeded. Node
        // uses this to tell the model which absolute path a command should use.
        if let guestPath = GuestWorkspaceCoordinator.shared.workspaceGuestPath {
            environment["DSH_GUEST_WORKSPACE"] = guestPath
        }
        // The two temporary roots, when the second mount came up. The provider
        // needs both spellings to respell the paths a plugin builds from the
        // HOST tmpdir into paths the guest can open — `dsh-workspace-changes`
        // does exactly that for its snapshot object store.
        let coordinator = GuestWorkspaceCoordinator.shared
        if let guestTemp = coordinator.temporaryGuestPath, let hostTemp = coordinator.temporaryHostPath {
            environment["DSH_GUEST_TMPDIR"] = guestTemp
            environment["DSH_HOST_TMPDIR"] = hostTemp
        }
        return environment
    }

    // MARK: - Starting Node

    private func startNode(argv: [String], environment: [String: String]) {
        // Node must run with the workspace as cwd: `cwd` defaults to "/", which
        // the app cannot write to.
        if chdir(workspace.path) != 0 {
            emit("dshportc: WARNING chdir to workspace failed (errno \(errno))")
        }
        for (key, value) in environment {
            setenv(key, value, 1)
        }

        let arguments = Argv(argv)
        let stdoutPipe = PipeOutputStream()
        stdoutPipe.attach()

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.writeStatus {
                $0.phase = BootPhase.nodeRunning.rawValue
                $0.detail = "node_start entered"
            }
            let status = node_start(arguments.count, arguments.pointer)
            self.emit("dshportc: node_start returned \(status)")
            self.noteFailure("node_start returned \(status)", runtimeFatal: true)
        }
        thread.name = "node"
        thread.stackSize = 8 << 20
        thread.start()

        stdoutPipe.startReading(onDiscard: { [weak self] limit in
            self?.emit("dshportc: discarded a pipe line exceeding \(limit) bytes")
        }) { [weak self] line in
            self?.consume(line)
        }
    }

    /// Parse DSH's own output stream.
    private func consume(_ line: String) {
        logQueue.async {
            self.handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Bridge payloads can carry conversation text even with notifications off.
        // Dispatch the original below without putting it in the log.
        if trimmed.hasPrefix("DSHPORTC_NOTIFY") {
            // Keep the compact, ordered turn-start metadata the acceptance reader uses.
            if trimmed.hasPrefix("DSHPORTC_NOTIFY "),
               let data = String(trimmed.dropFirst("DSHPORTC_NOTIFY ".count)).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["kind"] as? String == "turn-start",
               let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
               let metadata = try? JSONSerialization.data(
                   withJSONObject: ["kind": "turn-start", "sessionId": sessionId], options: [.sortedKeys]
               ),
               let json = String(data: metadata, encoding: .utf8) {
                emit("node| DSHPORTC_NOTIFY " + json)
            } else {
                emit("node| DSHPORTC_NOTIFY <payload omitted>")
            }
        } else if trimmed.hasPrefix("DSHPORTC_BUSY") {
            emit("node| DSHPORTC_BUSY <payload omitted>")
        } else {
            emit("node| " + trimmed)
        }

        // The runtime facts line the app asks Node to print at startup.
        if trimmed.hasPrefix("DSHPORTC_RUNTIME ") {
            applyRuntimeFacts(String(trimmed.dropFirst("DSHPORTC_RUNTIME ".count)))
            return
        }

        // Step 13: the busy bridge's state line. It arrives once per state
        // change (turn start, step start, tool call, turn end), never per token,
        // and it is the only source of truth for "is there work in flight right
        // now" — see plugins/dsh-busy-ios and PATCHES.md P-24. Dispatched on the
        // main queue because `BackgroundContinuation` is @MainActor and may have
        // to submit a background request from it.
        if trimmed.hasPrefix("DSHPORTC_BUSY ") {
            let payload = String(trimmed.dropFirst("DSHPORTC_BUSY ".count))
            DispatchQueue.main.async {
                BackgroundContinuation.shared.noteBridgeLine(payload)
            }
            return
        }

        // Step 16: the notification bridge's event line. One line per thing worth
        // telling the user about, plus one `turn-start` and the `dismiss` lines
        // that withdraw a banner whose reason is gone. Dispatched on the main queue
        // because `NotificationBridge` is @MainActor and talks to
        // `UNUserNotificationCenter` from it. See plugins/dsh-notify-ios and
        // PATCHES.md P-26.
        if trimmed.hasPrefix("DSHPORTC_NOTIFY ") {
            let payload = String(trimmed.dropFirst("DSHPORTC_NOTIFY ".count))
            DispatchQueue.main.async {
                NotificationBridge.shared.noteBridgeLine(payload)
            }
            return
        }

        // Step 19: the safe-mode decision. One line, published before DSH is
        // imported, so it is on screen before there is a page to put it on. The
        // payload is the same JSON `describeDecision()` produces.
        if trimmed.hasPrefix("DSHPORTC_SAFEMODE ") {
            applySafeMode(String(trimmed.dropFirst("DSHPORTC_SAFEMODE ".count)))
            return
        }

        // `ios-app-entry.mjs` caught a failing exit and parked Node.
        if trimmed.hasPrefix("DSHPORTC_FATAL ") {
            noteFailure(String(trimmed.dropFirst("DSHPORTC_FATAL ".count)), runtimeFatal: true)
            return
        }

        // The only place the launch token exists.
        guard trimmed.hasPrefix("dsh web: http") else { return }
        let raw = String(trimmed.dropFirst("dsh web: ".count))
        guard let url = URL(string: raw) else {
            emit("dshportc: could not parse web url")
            return
        }
        emit("dshportc: web url \(NodeRunner.redact(raw))")
        // Separate file, not the log: see `sessionURLFileURL`.
        try? raw.data(using: .utf8)?.write(to: sessionURLFileURL, options: .atomic)
        authenticatedURL = url
        writeStatus {
            guard $0.phase != BootPhase.failed.rawValue, $0.runtimeFatal != true else { return }
            $0.phase = BootPhase.serverListening.rawValue
            $0.detail = "server announced its URL"
            $0.webURL = NodeRunner.redact(raw)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dshServerReady, object: url)
        }
    }

    private func applyRuntimeFacts(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            emit("dshportc: unparsable runtime facts")
            return
        }
        writeStatus { status in
            status.node.nodeVersion = object["node"] as? String ?? ""
            status.node.v8Version = object["v8"] as? String ?? ""
            status.node.moduleVersion = object["modules"] as? String ?? ""
            status.node.napiVersion = object["napi"] as? String ?? ""
            status.node.platform = object["platform"] as? String ?? ""
            status.node.arch = object["arch"] as? String ?? ""
            status.node.webAssembly = object["webAssembly"] as? String ?? ""
            status.node.webAssemblyIsStub = object["webAssemblyIsStub"] as? Bool ?? false
            status.node.webAssemblyCompiles = object["webAssemblyCompiles"] as? Bool ?? false
            status.node.jitless = object["jitless"] as? Bool ?? false
            status.node.execArgv = object["execArgv"] as? [String] ?? []
            status.node.payloadPath = object["payload"] as? String ?? ""
            status.node.dshHome = object["dshHome"] as? String ?? ""
            status.node.workspace = object["workspace"] as? String ?? ""
            status.node.childProcessBlocked = object["childProcessBlocked"] as? Bool ?? false
            status.node.addonLoadingBlocked = object["addonLoadingBlocked"] as? Bool ?? false
        }
    }

    /// Parse and store the `DSHPORTC_SAFEMODE` line.
    ///
    /// Never throws into the boot path: a malformed line is one log entry, and
    /// the failure screen stays usable without a banner. The values are the ones
    /// `sim/safe-mode.mjs`'s `describeDecision()` and `boot-guard.mjs`'s
    /// `beginLaunch()` return, so what the banner says and what the guard decided
    /// cannot disagree.
    private func applySafeMode(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            emit("dshportc: unparsable safe mode line")
            return
        }
        var report = SafeModeReport()
        report.active = object["active"] as? Bool ?? false
        report.mode = object["mode"] as? String ?? "normal"
        report.skipped = object["skipped"] as? [String] ?? []
        report.reason = object["reason"] as? String ?? ""
        report.failures = object["failures"] as? Int ?? 0
        // `previous` is the settled verdict for the launch before this one, or
        // null when there was none. Flattened into `bootGuard` rather than kept
        // as `Any`, because the status file is `Codable` and an `Any` field would
        // have to be hand-encoded.
        var guardReport = BootGuard.report()
        guardReport.failures = report.failures
        if let previous = object["previous"] as? [String: Any] {
            guardReport.previousKind = previous["kind"] as? String ?? ""
            guardReport.previousReason = previous["reason"] as? String ?? ""
        }
        writeStatus {
            $0.safeMode = report
            $0.bootGuard = guardReport
        }
        emit(report.active
            ? "dshportc: SAFE MODE active, \(report.skipped.count) plugin(s) skipped: \(report.skipped.joined(separator: ", "))"
            : "dshportc: normal mode, \(report.failures) consecutive failure(s) on record")
    }

    // MARK: - Web view progress

    func noteWebViewLoading() {
        writeStatus {
            guard $0.phase != BootPhase.failed.rawValue, $0.runtimeFatal != true else { return }
            $0.phase = BootPhase.webViewLoading.rawValue
            $0.detail = "WKWebView loading"
            $0.clientStartupError = nil
        }
    }

    func noteDocumentLoaded() {
        writeStatus {
            guard $0.phase != BootPhase.failed.rawValue, $0.runtimeFatal != true else { return }
            $0.phase = BootPhase.documentLoaded.rawValue
            $0.detail = "WKWebView document loaded; waiting for DSH"
        }
    }

    func noteClientStartupError(_ message: String) {
        writeStatus {
            guard $0.clientStartupError == nil else { return }
            let safe = NodeRunner.redact(message)
            $0.clientStartupError = safe
            self.emit("dshportc: client startup diagnostic: " + safe)
        }
    }

    private func noteReadinessTimeout() {
        queue.async {
            let status = self.statusSnapshot
            guard status.phase != BootPhase.failed.rawValue,
                  status.phase != BootPhase.webViewReady.rawValue else { return }
            var message = "页面在 \(Int(BootGuard.pageReadyTimeout)) 秒内没有就绪"
            if let error = status.clientStartupError { message += "；客户端错误：" + error }
            self.fail(message)
        }
    }

    @discardableResult
    func noteWebViewReady() -> Bool {
        // Success and failure settle on the same queue. A delayed callback
        // cannot supersede a watchdog or fatal exit that already failed.
        queue.sync {
            let status = self.statusSnapshot
            guard status.phase != BootPhase.failed.rawValue,
                  status.error == nil, status.runtimeFatal != true else { return false }
            self.persistStatus {
                $0.phase = BootPhase.webViewReady.rawValue
                $0.detail = "DSH interface ready"
            }
            self.emit("dshportc: webview ready after \(String(format: "%.2f", Date().timeIntervalSince(self.launchDate)))s")
            BootGuard.cancelWatchdog()
            BootGuard.recordOutcome(
                kind: "success",
                reason: "the DSH interface came up",
                phase: BootPhase.webViewReady.rawValue,
                level: "page"
            )
            return true
        }
    }

    func noteFailure(_ message: String, runtimeFatal: Bool = false) {
        queue.async { self.fail(message, runtimeFatal: runtimeFatal) }
    }

    /// Caller is on the boot queue. Keep the first failure reason, but retain a
    /// later fatal exit even when a watchdog already failed this launch.
    private func fail(_ message: String, runtimeFatal: Bool = false) {
        let firstFailure = statusSnapshot.phase != BootPhase.failed.rawValue
        persistStatus {
            if runtimeFatal { $0.runtimeFatal = true }
            if firstFailure {
                $0.phase = BootPhase.failed.rawValue
                $0.detail = message
                $0.error = message
            }
        }
        if firstFailure {
            emit("dshportc: FAILED \(message)")
            BootGuard.cancelWatchdog()
            BootGuard.recordOutcome(kind: "failure", reason: message, phase: BootPhase.failed.rawValue)
        }
    }

    /// Record that the app went to the background, so the next launch can tell a
    /// swipe-away from a crash. Called from the scene-phase hook in
    /// `DSHPortCApp`.
    func noteEnteredBackground() {
        emit("dshportc: entering background; recording the launch id for the next boot")
        BootGuard.noteEnteredBackground()
        BootGuard.pauseWatchdog()
    }

    /// Back in the foreground: a launch still waiting for its page gets a full
    /// timeout again.
    func noteBecameActive() {
        BootGuard.noteBecameActive()
        BootGuard.resumeWatchdog()
    }

    /// Record one line from `BackgroundContinuation` in the boot log and mirror
    /// its current view into the status file.
    ///
    /// Two sinks on purpose. The log is the transcript a person reads; the status
    /// file is what a host-side script polls, and it has to reflect the state
    /// *after* the line rather than requiring the script to tail a log and parse
    /// it. `emit` already redacts, and the payload here is counts and session
    /// ids only — no prompt text, no tool arguments, no result text.
    /// `@MainActor` because the facts come from `BackgroundContinuation`, which is
    /// main-actor isolated and must not be read from the log queue: reading it
    /// there would race the very state the line is reporting, and the compiler is
    /// right to refuse. The caller is already on the main actor (the background
    /// lifecycle hops there before doing anything), so this costs no hop.
    @MainActor
    func noteBackgroundLine(_ line: String) {
        emit(line)
        let facts = BackgroundContinuation.shared.facts()
        writeStatus { status in
            var report = status.background ?? BackgroundReport()
            report.busy = facts["busy"] as? Bool ?? false
            report.turn = facts["turn"] as? Int ?? 0
            report.step = facts["step"] as? Int ?? 0
            report.tools = facts["tools"] as? Int ?? 0
            report.lastOutcome = facts["lastOutcome"] as? String ?? ""
            report.submissions = facts["submissions"] as? Int ?? 0
            report.completions = facts["completions"] as? Int ?? 0
            report.expirations = facts["expirations"] as? Int ?? 0
            report.holding = facts["holding"] as? Bool ?? false
            report.identifier = facts["identifier"] as? String ?? ""
            report.capabilities = facts["capabilities"] as? [String] ?? []
            report.lastStateChange = facts["lastStateChange"] as? String
            if #available(iOS 26.0, *) { report.apiAvailable = true }
            status.background = report
        }
    }

    /// Mirror `NotificationBridge`'s view into the status file.
    ///
    /// Same two-sink reasoning as `noteBackgroundLine`: the log is the transcript a
    /// person reads, and this file is what a host-side script polls. `notify` is a
    /// separate call rather than a merge because the bridge writes on more occasions
    /// than the background lifecycle does (a scene transition, a switch change, a
    /// tap), and threading them through one method would tie two independent states
    /// together for no benefit.
    func noteNotificationReport(_ report: NotificationReport) {
        writeStatus { status in
            status.notifications = report
        }
    }
}

enum BootError: Error, CustomStringConvertible {
    case missingResource(String)

    var description: String {
        switch self {
        case .missingResource(let path): return "missing bundle resource: \(path)"
        }
    }
}

extension Notification.Name {
    static let dshServerReady = Notification.Name("local.dshportc.serverReady")
}

/// `char **argv` for `node_start`, allocated on the heap and kept alive for the
/// life of the process.
///
/// A `withUnsafeMutableBufferPointer` array is not enough: the pointer is only
/// valid inside the closure, and Node's `uv_setup_args` reads `argv[0]` later on
/// its own thread, which segfaults inside `_platform_strlen`.
final class Argv {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    let count: Int32

    init(_ strings: [String]) {
        count = Int32(strings.count)
        pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    deinit {
        for index in 0..<Int(count) where pointer[index] != nil {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}

/// Redirects the process's fd 1 and 2 into a pipe and hands the app decoded lines.
///
/// DSH prints the launch token once, to stdout, and never again; without this
/// the app has no way to load the UI. `dup2` is what makes it work for writes
/// Node does after it has already captured its own `process.stdout`.
final class PipeOutputStream {
    private var readDescriptor: Int32 = -1
    private var writeDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "local.dshportc.pipe")

    func attach() {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        dup2(writeDescriptor, STDOUT_FILENO)
        dup2(writeDescriptor, STDERR_FILENO)
        close(writeDescriptor)
        // Line buffering so a partial line still reaches the app promptly.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    func startReading(onDiscard: @escaping (Int) -> Void, handler: @escaping (String) -> Void) {
        let descriptor = readDescriptor
        queue.async {
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            var lines = PipeLineBuffer()
            while true {
                let read = Darwin.read(descriptor, buffer, bufferSize)
                if read < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if read == 0 {
                    lines.finish(handler: handler)
                    break
                }
                lines.append(Data(bytes: buffer, count: read), onDiscard: onDiscard, handler: handler)
            }
        }
    }
}

/// Imported with `@_silgen_name` so no bridging header is needed for the one
/// symbol nodejs-mobile exports.
@_silgen_name("node_start")
func node_start(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
