//
//  BackgroundContinuation.swift
//  DSHPortC
//
//  Keeps a running turn alive when the app goes to the background, and ends the
//  request as soon as the turn does.
//
//  THE PROBLEM, MEASURED
//  ---------------------
//  Report 4B put the app in the background for 30 s, 120 s and 300 s and read a
//  2-second heartbeat file afterwards. The heartbeat gap equalled the entire
//  background duration every time (30.4 s, 123.4 s, 301.7 s) with the same pid
//  and no crash log: the process was suspended almost immediately, not after
//  "about 30 seconds" as the older comment in DSHPortCApp.swift guessed. Node is
//  in-process, so a suspended process means a frozen model turn, a frozen tool
//  call and a frozen guest command — the turn survives, but it does not progress.
//
//  WHAT THIS ADDS
//  --------------
//  iOS 26 introduced `BGContinuedProcessingTask`: a task that STARTS in the
//  foreground, is submitted in response to a user action, and is allowed to keep
//  running after the app is backgrounded, while the system shows its progress in
//  a Live Activity the user can cancel from. That is exactly the shape of "I sent
//  a message and switched apps while it works".
//
//  The lifecycle is:
//
//    1. The busy bridge (`plugins/dsh-busy-ios`) reports one line per change to
//       the durable turn state, so the shell knows whether work is in flight.
//    2. When a turn starts with the app in the foreground, submit a request. The
//       send tap has only just happened, and this is the only moment the system
//       accepts: REPORT-12 submitted from `didEnterBackground` and `submit`
//       succeeded, yet the system never launched the task. An idle app submits
//       nothing, because asking would show a system task for no work.
//    3. While it runs, report progress on every bridge line. Steps and tool calls
//       are too sparse for a long generation or a silent command, so the bridge
//       also beats while a turn is in flight; a beat proves Node is alive, not
//       that the turn is getting anywhere, and it is never shown as a percentage.
//    4. On `turn/end`, end the task ourselves. Coming back to the foreground does
//       not end it, or a second trip away would have nothing keeping it alive.
//    5. Backgrounding a running turn without a live task means it is about to
//       freeze, so say so while the process can still post a notification.
//    6. On expiration or user cancellation, put Node and the guest into a state
//       they can be resumed from, and say so in the log. The session is not
//       touched: the turn's durable log is what makes the next launch resumable.
//
//  WHY THE OBSERVATION IS A STDOUT LINE AND NOT A WEB VIEW CALL
//  ------------------------------------------------------------
//  At the moment this has to decide, the app is already backgrounded. A
//  backgrounded WKWebView may be throttled, so `evaluateJavaScript` could return
//  long after the decision had to be made — and a DOM read answers "did the UI
//  last paint something that looks busy", which is not the same question. The
//  bridge reads the durable event stream instead, which is what the UI renders
//  from, and prints it. See PATCHES.md P-25.
//
//  GATING
//  ------
//  Everything here is inert unless iOS 26+ is present (the API does not exist
//  below that) and the continued-processing identifier is in Info.plist. Both are
//  runtime facts, so the class reports which one is missing rather than failing
//  at launch. No launch argument is needed: unlike the measurement probes, this
//  is the feature itself.
//

import BackgroundTasks
import Foundation
import UIKit

/// How far along the running turn is, as reported by the busy bridge.
struct BusyState: Equatable {
    var busy: Bool = false
    var turn: Int = 0
    var step: Int = 0
    var tools: Int = 0
    /// When the last state change arrived, so a stale busy can be recognised.
    var updatedAt: Date = .distantPast

    /// The subtitle the system shows. Reports what is actually known.
    ///
    /// Deliberately not a percentage: the harness cannot know how many steps a
    /// turn will take, and a made-up denominator would make the progress bar
    /// reach 100% while the turn was still working — which is worse than an
    /// indeterminate bar, because the system uses apparent lack of progress to
    /// decide a task is stuck and to prioritise terminating it.
    var subtitle: String {
        guard busy else { return "空闲" }
        if tools > 0 {
            return "第 \(max(turn, 1)) 轮 · 第 \(max(step, 1)) 步 · \(tools) 个工具调用"
        }
        return "第 \(max(turn, 1)) 轮 · 第 \(max(step, 1)) 步"
    }
}

@MainActor
final class BackgroundContinuation {
    static let shared = BackgroundContinuation()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    ///
    /// The prefix is the bundle id and the last segment is `*`, per the header's
    /// wildcard rule: `<MainBundle>.<SemanticContext>.*`, with the submitted
    /// identifier ending in a per-job suffix. A mismatch here is the difference
    /// between `submit` succeeding and `BGTaskSchedulerErrorCodeNotPermitted`,
    /// so the launch log prints both the identifier and whether the plist
    /// declared it, rather than leaving a silent failure to be guessed at.
    static let identifierPrefix = "local.dshportc.app.continued-processing."

    /// The exact identifier currently registered, if any. Registration may only
    /// happen once per identifier per process, so a new turn uses a new one.
    private var registeredIdentifier: String?
    /// Storage is `AnyObject?` because a stored property's type must be usable on
    /// every deployment target this app supports, and the app's floor is iOS 17
    /// while `BGContinuedProcessingTask` is 26. The typed accessor below is the
    /// only place the concrete type appears, and it is `@available`-gated, so no
    /// caller can reach it without an availability check.
    private var runningTaskStorage: AnyObject?
    private var currentJobIdentifier: String?
    /// Submitted, and the system has not launched it yet.
    private var awaitingLaunch = false
    /// The system took this turn's task back, or the user cancelled it. Asking
    /// again would undo a cancel, and the handler cannot tell the two apart.
    private var expiredThisTurn = false
    /// Every bridge line is one unit, so the bar only ever moves forward.
    private var progressUnits: Int64 = 0
    private var disabled = false

    @available(iOS 26.0, *)
    private var runningTask: BGContinuedProcessingTask? {
        get { runningTaskStorage as? BGContinuedProcessingTask }
        set { runningTaskStorage = newValue }
    }

    private(set) var state = BusyState()
    private(set) var lastOutcome: String = "未申请"
    private(set) var submissionCount = 0
    private(set) var completionCount = 0
    private(set) var expirationCount = 0

    /// True when the running turn is being kept alive by a system task.
    ///
    /// Read through `AnyObject?` rather than the gated property, because this is
    /// asked from non-isolated code as well (see `facts()`); the question "is
    /// anything stored here" needs no iOS 26 API.
    var isHoldingBackgroundTask: Bool { runningTaskStorage != nil }

    private var started = false

    /// The parts of the mechanism that are facts about this OS, not about code.
    func capabilityFacts() -> [String] {
        var facts: [String] = []
        if #available(iOS 26.0, *) {
            facts.append("BGContinuedProcessingTask: 可用（iOS \(UIDevice.current.systemVersion)）")
            let support = BGTaskScheduler.supportedResources
            facts.append("supportedResources: \(support.contains(.gpu) ? "default+gpu" : "default")")
        } else {
            facts.append("BGContinuedProcessingTask: 不可用（iOS \(UIDevice.current.systemVersion) < 26）")
        }
        return facts
    }

    // MARK: - Wiring

    /// Record the capability facts and subscribe to the two lifecycle moments
    /// this class cares about. Called once from the app's `onAppear`.
    func start() {
        guard !started else { return }
        started = true
        // The control arm of step 12's device test: the same build, never asking
        // iOS for background time. An environment variable because devicectl
        // cannot pass a dash-prefixed launch argument.
        if ProcessInfo.processInfo.environment["DSHPORTE_BG_DISABLE"] == "1" {
            emit("dshportc: bg disabled by DSHPORTE_BG_DISABLE")
            disabled = true
            return
        }
        for fact in capabilityFacts() {
            emit("dshportc: bg " + fact)
        }
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidEnterBackground() }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWillEnterForeground() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.submitIfForegroundTurnNeedsIt() }
        }
        scheduleSimulatedExpiration()
    }

    /// Feed one `DSHPORTC_BUSY {...}` payload from Node's stdout.
    ///
    /// Malformed input is ignored rather than fatal: this runs on the app's line
    /// dispatcher, and a parse error there must not be able to take down the
    /// thing that reads the launch URL.
    func noteBridgeLine(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let busy = object["busy"] as? Bool
        else {
            emit("dshportc: bg ignored a malformed busy line")
            return
        }
        let sessions = object["sessions"] as? [[String: Any]] ?? []
        // The most-progressed session is the one worth reporting. With one turn
        // running (the normal case) this is just that turn; with several, the
        // subtitle should describe the work that has been going longest.
        let lead = sessions.max { lhs, rhs in
            let l = (lhs["tools"] as? Int ?? 0, lhs["step"] as? Int ?? 0)
            let r = (rhs["tools"] as? Int ?? 0, rhs["step"] as? Int ?? 0)
            return l < r
        }
        let next = BusyState(
            busy: busy,
            turn: lead?["turn"] as? Int ?? 0,
            step: lead?["step"] as? Int ?? 0,
            tools: lead?["tools"] as? Int ?? 0,
            updatedAt: Date()
        )
        let wasBusy = state.busy
        state = next
        if wasBusy != next.busy {
            emit("dshportc: bg turn \(next.busy ? "started" : "ended") (\(next.subtitle))")
        }
        if next.busy {
            if !wasBusy { submitIfForegroundTurnNeedsIt() }
            progressUnits += 1
            reportProgress()
        } else if wasBusy {
            expiredThisTurn = false
            NotificationBridge.shared.withdrawBackgroundPause()
            cancelUnlaunchedRequest()
            // The turn finished. End the request now rather than letting the
            // system expire it: an assertion held with nothing to do is pure
            // battery cost, and the header says the system prioritises
            // terminating exactly those.
            finishTask(success: true, reason: "turn ended")
        }
    }

    // MARK: - The background transition

    private func handleDidEnterBackground() {
        guard state.busy else {
            lastOutcome = "未申请：没有进行中的一轮"
            emit("dshportc: bg idle, so no continued-processing request was submitted")
            return
        }
        guard runningTaskStorage == nil else {
            emit("dshportc: bg already holding a continued-processing task")
            return
        }
        // Nothing is keeping this turn alive. The short assertion is only there so
        // the notification is posted before the process freezes: REPORT-12 measured
        // suspension as soon as 0 s after backgrounding.
        emit("dshportc: bg turn \(state.turn) will freeze — backgrounded without a running task")
        let application = UIApplication.shared
        var assertion = UIBackgroundTaskIdentifier.invalid
        let release = {
            guard assertion != .invalid else { return }
            application.endBackgroundTask(assertion)
            assertion = .invalid
        }
        assertion = application.beginBackgroundTask(withName: "dsh-pause-notice", expirationHandler: release)
        NotificationBridge.shared.noteBackgroundExpiration(turn: state.turn, step: state.step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: release)
    }

    private func handleWillEnterForeground() {
        // The turn keeps its task: the user may leave again before it ends.
        NotificationBridge.shared.withdrawBackgroundPause()
    }

    /// Ask for the task while the system still counts this as the user's action.
    private func submitIfForegroundTurnNeedsIt() {
        guard #available(iOS 26.0, *), !disabled, state.busy, !expiredThisTurn,
              runningTask == nil, !awaitingLaunch
        else { return }
        guard UIApplication.shared.applicationState == .active else {
            lastOutcome = "未申请：回合开始时 App 不在前台"
            emit("dshportc: bg not submitting for turn \(state.turn) — the app is not in the foreground")
            return
        }
        submit(jobIdentifier: Self.identifierPrefix + UUID().uuidString.prefix(8))
    }

    private func cancelUnlaunchedRequest() {
        guard awaitingLaunch, let identifier = currentJobIdentifier else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        awaitingLaunch = false
        currentJobIdentifier = nil
        emit("dshportc: bg cancelled \(identifier), which the system never launched")
    }

    // MARK: - Submission

    @available(iOS 26.0, *)
    private func submit(jobIdentifier: String) {
        let scheduler = BGTaskScheduler.shared

        // Registration is per identifier and may only happen once. `nil` queue
        // means the default background queue; the handler hops back to the main
        // actor because everything it touches is @MainActor.
        let registered = scheduler.register(forTaskWithIdentifier: jobIdentifier, using: nil) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { return }
            Task { @MainActor in self?.adopt(continued) }
        }
        guard registered else {
            lastOutcome = "注册失败：标识符不在 BGTaskSchedulerPermittedIdentifiers 里"
            emit("dshportc: bg register FAILED for \(jobIdentifier) — not declared in Info.plist, nothing submitted")
            return
        }
        registeredIdentifier = jobIdentifier
        currentJobIdentifier = jobIdentifier

        let request = BGContinuedProcessingTaskRequest(
            identifier: jobIdentifier,
            title: "DSH 正在处理",
            subtitle: state.subtitle
        )
        // `.fail` rather than `.queue`: the turn is already running, so a task that
        // starts later protects nothing in between. A refusal here is an answer the
        // log can show; a queued request looks like success and may never launch.
        request.strategy = .fail

        do {
            try scheduler.submit(request)
            awaitingLaunch = true
            submissionCount += 1
            lastOutcome = "已提交（\(jobIdentifier)）"
            emit("dshportc: bg submitted \(jobIdentifier) for turn \(state.turn) step \(state.step); \(state.subtitle)")
        } catch {
            let nsError = error as NSError
            currentJobIdentifier = nil
            lastOutcome = "提交失败：\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
            emit("dshportc: bg submit FAILED \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        }
    }

    // MARK: - Running

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        awaitingLaunch = false
        guard state.busy else {
            // The turn ended between `submit` and this launch.
            task.setTaskCompleted(success: true)
            emit("dshportc: bg system launched the task after the turn ended, so it was completed at once")
            return
        }
        runningTask = task
        // The header is explicit that a continued-processing task MUST report
        // progress: apparent lack of progress is what makes the scheduler judge a
        // task stuck and expire it early.
        //
        // The denominator is the number of bridge lines observed SO FAR, not a guess
        // at the total. `Progress` treats an increase of `totalUnitCount` as forward
        // movement, and each line raises it by one while `completedUnitCount` trails
        // by one, so the bar advances monotonically without ever claiming to be
        // finished while the turn is still running.
        progressUnits = 0
        let progress = task.progress
        progress.totalUnitCount = 1
        progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.handleExpiration() }
        }
        emit("dshportc: bg system launched the task — the process may now keep working in the background")
        reportProgress()
    }

    private func reportProgress() {
        if #available(iOS 26.0, *) { reportProgressOnTask() }
    }

    @available(iOS 26.0, *)
    private func reportProgressOnTask() {
        guard let task = runningTask else { return }
        let progress = task.progress
        progress.totalUnitCount = progressUnits + 1
        progress.completedUnitCount = progressUnits
        task.updateTitle("DSH 正在处理", subtitle: state.subtitle)
    }

    private func handleExpiration() {
        expirationCount += 1
        expiredThisTurn = true
        // Two distinct causes reach this handler — the user cancelling from the
        // system UI, and the system reclaiming the task — and the handler takes
        // no arguments, so they cannot be told apart. Say that instead of
        // guessing.
        lastOutcome = "系统收回（或被用户取消；expirationHandler 不带原因，无法区分）"
        emit("dshportc: bg EXPIRED — system reclaimed the task, or the user cancelled it from the system UI")

        // Step 16's sixth requirement. The process is about to be suspended, so the
        // turn the user is waiting for will not finish and will not notify. Without
        // this line they would keep waiting for a notification that cannot come.
        //
        // Filed under the ERROR switch, as the task specifies, and only when a turn
        // is still running: an idle app being reclaimed has nothing to warn about.
        //
        // The honest caveat is the one already in `lastOutcome` above: this handler
        // is also what a USER cancellation reaches, so a user who cancels from the
        // system UI gets this notification too. The task says that extra one is
        // acceptable rather than something to guess around, and guessing would mean
        // either lying about the cause or dropping the warning for the common case.
        if state.busy {
            NotificationBridge.shared.noteBackgroundExpiration(turn: state.turn, step: state.step)
        }

        // Get Node and the guest into a state they can be resumed from.
        //
        // Nothing is torn down: the turn's durable log is already on disk and
        // `turn/end` (or its absence) is exactly what makes the next launch able
        // to resume. Killing Node here would lose the in-flight tool call for no
        // benefit, because the process is about to be suspended anyway.
        //
        // What IS done: flush the session log, so the events already produced are
        // fsynced rather than sitting in a write buffer that a suspension might
        // outlive. That is the one thing that makes "resume and keep going"
        // honest rather than optimistic.
        finishTask(success: false, reason: "expired")
    }

    private func finishTask(success: Bool, reason: String) {
        if #available(iOS 26.0, *) { completeOnTask(success: success, reason: reason) }
    }

    @available(iOS 26.0, *)
    private func completeOnTask(success: Bool, reason: String) {
        guard let task = runningTask else { return }
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        completionCount += 1
        lastOutcome = success ? "已结束（\(reason)）" : lastOutcome
        emit("dshportc: bg task completed success=\(success) reason=\(reason)")
        runningTask = nil
        currentJobIdentifier = nil
    }


    // MARK: - Simulating a reclaim

    /// Invoke the expiration path on demand, for the acceptance run.
    ///
    /// WHY A HOOK AND NOT A REAL EXPIRATION. The system calls `expirationHandler`
    /// when it reclaims a task, and there is no supported way to ask it to do that
    /// — on a device you can only wait for a resource-pressure event, and on the
    /// simulator the scheduler is not available at all (measured: submission
    /// returns `BGTaskSchedulerErrorDomain 1`). Without a hook, the recovery path
    /// would ship untested and the report could only say "it compiles".
    ///
    /// So this calls THE SAME `handleExpiration()` the framework calls. What it
    /// proves: the cleanup path runs, does not crash the app, and leaves Node and
    /// the session usable afterwards. What it does NOT prove: that the system
    /// reaches this handler at the moment, or with the timing, a real device
    /// would — that is named in the report as a device-only question.
    ///
    /// Gated on a launch argument, so a normal launch can never reach it:
    /// `-DSHPortESimulateExpiration <seconds>`.
    func scheduleSimulatedExpiration() {
        let seconds = UserDefaults.standard.double(forKey: "DSHPortESimulateExpiration")
        guard seconds > 0 else { return }
        emit("dshportc: bg will simulate an expiration in \(Int(seconds))s (debug hook)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.emit("dshportc: bg SIMULATED expiration now (debug hook, not the system)")
                self.handleExpiration()
            }
        }
    }

    // MARK: - Observability

    private func emit(_ line: String) {
        NodeRunner.shared.noteBackgroundLine(line)
    }

    /// Everything the report needs to state what happened, written to the app's
    /// own status-adjacent probe file when the step-13 acceptance asks for it.
    func facts() -> [String: Any] {
        var out: [String: Any] = [
            "busy": state.busy,
            "turn": state.turn,
            "step": state.step,
            "tools": state.tools,
            "lastOutcome": lastOutcome,
            "submissions": submissionCount,
            "completions": completionCount,
            "expirations": expirationCount,
            "holding": isHoldingBackgroundTask,
            "identifier": currentJobIdentifier ?? registeredIdentifier ?? "",
            "capabilities": capabilityFacts(),
        ]
        if state.updatedAt != .distantPast {
            out["lastStateChange"] = ISO8601DateFormatter().string(from: state.updatedAt)
        }
        return out
    }
}
