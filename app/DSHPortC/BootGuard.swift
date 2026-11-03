//
//  BootGuard.swift
//  DSHPortC
//
//  The Swift half of the boot guard: the launch id, the outcome file, the
//  background marker, the page watchdog, and the one-shot requests the next
//  launch reads.
//
//  WHY SWIFT WRITES ANY OF THIS
//  ----------------------------
//  The counter itself lives in Node (`sim/boot-guard.mjs`), because the launch it
//  has to survive is Node's. But three of the four facts it needs are facts only
//  this process has:
//
//    * whether the WEB VIEW finished, which is `WKWebView.didFinish` and is not
//      visible from inside Node at all;
//    * whether the app went to the background before it ended, which is
//      `scenePhase` and is the only way to tell "the user swiped it away" from
//      "it died";
//    * whether the page ever arrived, which is a timeout this side has to run.
//
//  So the two processes exchange files, one writer each, and this file is the
//  Swift writer for `boot-outcome.json`, `boot-background.txt` and
//  `boot-request.json`. The rule that makes it safe is the same one the Node
//  module states: a file with exactly one writer cannot lose an update.
//
//  THE WATCHDOG'S THRESHOLD
//  ------------------------
//  60 seconds. Step 21 measured this device's cold starts at 4.57 / 4.74 / 5.72 s
//  (median 4.74), so 60 s is more than ten times the observed worst case — a slow
//  machine or a one-off cold-cache launch is not mistaken for a broken one. It
//  also has to be shorter than a person's patience, because the point of the
//  timeout is to turn "nothing is happening" into a screen with a reason and two
//  buttons on it.
//

import Foundation

/// What one launch's terminal answer looks like on disk.
///
/// The field names match `isOutcomeRecord()` / `fromOutcome()` in
/// `sim/boot-guard.mjs`. `kind` and `launchId` are the only required ones there;
/// everything else is defaulted when missing, so a field added here later does
/// not make an older reader reject the file.
struct BootOutcome: Codable {
    var version = 1
    var launchId: String
    /// `success` or `failure`. The Node side treats anything else as a failure.
    var kind: String
    /// `page` when the web view painted, `server` when only the URL was known.
    var level: String
    /// The sentence the boot log and the failure screen show.
    var reason: String
    /// The step the launch reached; `webViewReady` for a success.
    var phase: String
    var at: String
}

/// What `safe-mode.mjs`'s `DSHPORTC_SAFEMODE` line carries, parsed.
///
/// Written into `BootStatus.safeMode` so a host-side script can read it from one
/// place instead of scraping the log, which is the same rule the background and
/// notification reports follow.
struct SafeModeReport: Codable {
    var active = false
    var mode = "normal"
    var skipped: [String] = []
    var reason = ""
    /// How many launches in a row had failed when this decision was made.
    var failures = 0
}

/// The guard's own state, as much of it as the failure screen wants to show.
struct GuardReport: Codable {
    var failures = 0
    var threshold = 3
    var safeMode = false
    var safeModeFailures = 0
    var stateStatus = ""
    /// `success` / `failure` / `abandoned`: what the PREVIOUS launch turned out
    /// to be, which is the fact that explains why this one is in safe mode.
    var previousKind = ""
    var previousReason = ""
}

/// The reset planner's answer for one combination of options, as Swift needs it.
///
/// Two sources, one shape. Node writes `boot/reset-plan.json` at every launch;
/// when it does not exist (a launch that never got that far) the built-in table
/// below answers instead. `ResetSheet` reads this and nothing else.
struct ResetPlanPreview: Codable {
    var source = ""
    var generatedAt = ""
    var warnings: [String] = []
    var combos: [String: ResetCombo] = [:]
}

struct ResetCombo: Codable {
    var keepConversations = false
    var keepSettings = false
    /// Container-relative paths this combination moves.
    var move: [String] = []
    /// Container-relative paths it keeps, with the reason.
    var keep: [ResetKeepEntry] = []
}

struct ResetKeepEntry: Codable {
    var relative = ""
    var reason = ""
}

/// One entry of the built-in fallback table.
struct ResetTierEntry {
    let relative: String
    let reason: String
    /// `always`, `conversations`, `settings` or `guest`.
    let tier: String
}

enum BootGuard {

    // MARK: - The launch id

    /// This launch's id, minted once and published to Node through the
    /// environment (`DSHPORTE_BOOT_LAUNCH_ID`).
    ///
    /// A `UUID` rather than a timestamp: the guard compares ids for equality, and
    /// two launches inside the same millisecond would make a timestamp ambiguous
    /// in exactly the case the comparison exists for (a quick double relaunch).
    static let launchId = UUID().uuidString

    /// How long the page has to paint before the launch is called a failure.
    static let pageReadyTimeout: TimeInterval = 60

    /// Guards `recordOutcome` so one launch writes at most one conclusion.
    ///
    /// Load-bearing: `node_start returned` can arrive HOURS after a successful
    /// launch (it returns when the server stops), and without this flag that
    /// would overwrite a `success` with a `failure` and count a failure for a
    /// launch that worked.
    private static let outcomeLock = NSLock()
    private static var outcomeWritten = false

    // MARK: - Outcome

    /// Append this launch's conclusion, once.
    ///
    /// WHY APPEND, NOT OVERWRITE
    /// ------------------------
    /// A launch can fail before Node starts: a missing `payload/`, a profile that
    /// will not render, the fail-fast switch. On those launches `beginLaunch()`
    /// never runs, so nothing consumes this file between failures, and an
    /// overwrite would leave ONE record on disk no matter how many times the app
    /// failed. The counter would sit at 0 while every launch failed — the exact
    /// situation safe mode exists for.
    ///
    /// Measured on the simulator before this changed: three consecutive
    /// `-DSHPortEBootFailFast 1` launches produced no `boot-guard.json` at all and
    /// a single `boot-outcome.json`, because each launch replaced the previous
    /// one's.
    ///
    /// So the file is a list: one compact JSON object per line. `boot-guard.mjs`
    /// is the only reader and the only thing that deletes it, and it settles every
    /// record on the next launch that gets far enough to run. Compact rather than
    /// pretty-printed on purpose — a multi-line object would need a parser on the
    /// Node side instead of one line per record.
    ///
    /// @param kind `success` or `failure`.
    /// @param reason the sentence for the log and the failure screen.
    /// @param phase the boot step reached (`webViewReady`, `failed`, …).
    /// @param level `page` or `server`; ignored for a failure.
    /// @returns whether the write happened. A second call in the same launch
    ///          returns `false` and leaves the first answer in place.
    @discardableResult
    static func recordOutcome(kind: String, reason: String, phase: String, level: String = "page") -> Bool {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        guard !outcomeWritten else { return false }
        let outcome = BootOutcome(
            launchId: launchId,
            kind: kind,
            level: level,
            reason: reason,
            phase: phase,
            at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(outcome)
            data.append(0x0A)
            let file = RuntimePaths.bootOutcomeFile
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
            outcomeWritten = true
            return true
        } catch {
            // The guard must never be the reason a launch fails. This is the one
            // place where "could not write" is worth a line in the boot log, so
            // the reason a later screen cannot explain itself is visible.
            NSLog("dshportc: could not write boot-outcome.json: %@", "\(error)")
            return false
        }
    }

    // MARK: - The background marker

    /// Record that this launch went to the background.
    ///
    /// This is what makes "the user swiped the app away" NOT a failure. The next
    /// launch reads this file: a launch that never wrote an outcome and left this
    /// marker ended while it was in the background, which is a user action (or
    /// iOS reclaiming a suspended app), not a boot that failed.
    ///
    /// Written on every `.background` transition, not only the first: the file is
    /// one line, the write is atomic, and the last transition before the process
    /// dies is the one that matters.
    static func noteEnteredBackground() {
        do {
            try (launchId + "\n").write(to: RuntimePaths.bootBackgroundFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("dshportc: could not write boot-background.txt: %@", "\(error)")
        }
    }

    // MARK: - Requests for the next launch

    /// Ask the next launch to do one thing, then quit.
    ///
    /// `exit-safe-mode` and `clear-guard` are consumed by `boot-guard.mjs`; any
    /// other action is left in the file for whoever owns it. The file is written
    /// before `exit(0)`, so a launch that is killed on the way out still leaves
    /// the request behind.
    ///
    /// @returns whether the request reached disk.
    @discardableResult
    static func request(_ action: String) -> Bool {
        let payload: [String: Any] = [
            "version": 1,
            "action": action,
            "id": UUID().uuidString,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: RuntimePaths.bootRequestFile, options: .atomic)
            return true
        } catch {
            NSLog("dshportc: could not write boot-request.json: %@", "\(error)")
            return false
        }
    }

    // MARK: - The watchdog

    private static let watchdogLock = NSLock()
    private static var watchdog: DispatchWorkItem?
    private static var watchdogTimeout: (() -> Void)?

    /// Start the page-ready timeout. Cancelled by `cancelWatchdog()`.
    ///
    /// @param onTimeout called on the main queue when the page has not painted
    ///        within `pageReadyTimeout`.
    static func startWatchdog(onTimeout: @escaping () -> Void) {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        watchdog?.cancel()
        watchdogTimeout = onTimeout
        armWatchdog()
    }

    /// Stop the timeout for this launch. A launch that has already answered
    /// either way must not be answered again: called from the Node thread and the
    /// boot queue as well as main, hence the lock.
    static func cancelWatchdog() {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        watchdog?.cancel()
        watchdog = nil
        watchdogTimeout = nil
    }

    /// Hold the timeout while the app is in the background. iOS suspends Node
    /// there, so a launch that was switched away from is not slow, and the timer
    /// would otherwise fire the moment the user came back.
    static func pauseWatchdog() {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        watchdog?.cancel()
        watchdog = nil
    }

    /// Give a paused launch a full timeout from now. Does nothing once the launch
    /// has answered, because that clears `watchdogTimeout`.
    static func resumeWatchdog() {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        guard watchdog == nil, watchdogTimeout != nil else { return }
        armWatchdog()
    }

    /// Caller holds `watchdogLock`.
    private static func armWatchdog() {
        guard let onTimeout = watchdogTimeout else { return }
        let item = DispatchWorkItem {
            cancelWatchdog()
            onTimeout()
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + pageReadyTimeout, execute: item)
    }

    // MARK: - The state file, read side

    /// Read `boot/boot-guard.json` for the failure screen.
    ///
    /// Tolerant on purpose: this is read by a screen that exists BECAUSE
    /// something is broken, so a missing or corrupt file has to answer something
    /// rather than throw. A missing file means "the guard never ran", which is a
    /// fact worth showing as `stateStatus: "missing"` rather than as zeros.
    static func report() -> GuardReport {
        var report = GuardReport()
        guard let data = try? Data(contentsOf: RuntimePaths.bootGuardFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report.stateStatus = FileManager.default.fileExists(atPath: RuntimePaths.bootGuardFile.path)
                ? "corrupt"
                : "missing"
            return report
        }
        report.stateStatus = "ok"
        report.failures = root["failures"] as? Int ?? 0
        report.threshold = root["threshold"] as? Int ?? 3
        report.safeMode = root["safeMode"] as? Bool ?? false
        report.safeModeFailures = root["safeModeFailures"] as? Int ?? 0
        if let last = root["lastOutcome"] as? [String: Any] {
            report.previousKind = last["kind"] as? String ?? ""
            report.previousReason = last["reason"] as? String ?? ""
        }
        return report
    }

    /// The reset preview, from Node's file if it is there and from the built-in
    /// table if it is not.
    ///
    /// THE FALLBACK IS NOT A CONVENIENCE. `boot/reset-plan.json` is written by
    /// Node at launch, and the one screen that needs it — the failure screen —
    /// is the screen of a launch where Node did not get that far. Without the
    /// built-in table the reset button on that screen would have nothing to show
    /// and nothing to execute, which is the situation the whole step exists to
    /// end ("the only way out is to delete the app").
    ///
    /// The two tables are kept in step by `scripts/reset-plan-parity.py`, which
    /// compares `ResetSheet.builtinTiers` against `TIERS` in
    /// `sim/reset-plan.mjs`. That comparison is a build-time check precisely
    /// because two copies of one table is how a data-loss bug starts.
    static func resetPreview() -> ResetPlanPreview {
        if let preview = readNodeResetPreview() { return preview }
        var preview = ResetPlanPreview()
        preview.source = "builtin"
        preview.generatedAt = ISO8601DateFormatter().string(from: Date())
        preview.warnings = ["boot/reset-plan.json 不存在或无法解析：清单来自 App 内置的同一份相对路径表。"]
        preview.combos = ResetSheet.builtinCombos()
        return preview
    }

    /// Node's `boot/reset-plan.json`, in the shape the sheet wants.
    ///
    /// `reset-plan.mjs`'s `previewCombos()` writes `{combos: {key: {keepConversations,
    /// keepSettings, move: [{relative, tier, reason}], keep: [...], missing, warnings}}}`.
    /// This flattens it to the two lists the sheet displays.
    private static func readNodeResetPreview() -> ResetPlanPreview? {
        guard let data = try? Data(contentsOf: RuntimePaths.resetPreviewFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let combos = root["combos"] as? [String: Any] else { return nil }
        var preview = ResetPlanPreview()
        preview.source = "node"
        preview.generatedAt = root["generatedAt"] as? String ?? ""
        if let errors = root["errors"] as? [[String: Any]] {
            preview.warnings = errors.compactMap { $0["error"] as? String }
        }
        for (key, value) in combos {
            guard let combo = value as? [String: Any] else { continue }
            var entry = ResetCombo()
            entry.keepConversations = combo["keepConversations"] as? Bool ?? false
            entry.keepSettings = combo["keepSettings"] as? Bool ?? false
            entry.move = (combo["move"] as? [[String: Any]] ?? []).compactMap { $0["relative"] as? String }
            entry.keep = (combo["keep"] as? [[String: Any]] ?? []).compactMap { item -> ResetKeepEntry? in
                guard let relative = item["relative"] as? String else { return nil }
                var keep = ResetKeepEntry()
                keep.relative = relative
                keep.reason = item["reason"] as? String ?? ""
                return keep
            }
            preview.combos[key] = entry
        }
        return preview.combos.isEmpty ? nil : preview
    }
}
