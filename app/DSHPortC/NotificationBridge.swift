//
//  NotificationBridge.swift
//  DSHPortC
//
//  Puts a local notification on the phone when the user is looking at another app
//  and one of four things happens: a turn finishes, a turn fails, a tool is waiting
//  for approval, or the agent asks a question. Each of the four can be switched off
//  on its own.
//
//  WHY LOCAL NOTIFICATIONS, AND WHAT THAT BOUNDS
//  ---------------------------------------------
//  A local notification is drawn by the system on this device from a request this
//  process hands to `UNUserNotificationCenter`. There is no server in the loop, and
//  that is exactly why the feature has a hard edge: a request can only be handed
//  over while this process is alive. iOS suspends the process roughly 30 seconds
//  after the app leaves the foreground — REPORT-4B measured 30.4 / 123.4 / 301.7 s
//  heartbeat gaps on a device and REPORT-13 §3.2 re-measured the simulator at
//  28–35 s. So a notification is only possible while:
//
//    * the app was backgrounded less than ~30 s ago and the process has not been
//      suspended yet, or
//    * step 13's continued-processing task is alive, which is the case where a turn
//      is still running in the background.
//
//  Once the process is suspended, nothing on this device can wake it to post a
//  notification. The session log still records what happened, so the app shows the
//  result when the user comes back; the notification is the convenience, not the
//  record. REPORT-16 §6 states this limit instead of implying the feature is
//  unconditional.
//
//  WHEN NOT TO POST
//  ----------------
//  Foreground: the user is looking at the app, so a banner over it would be noise —
//  the request is recorded as suppressed instead. Cancelled turns: the plugin does
//  not report them at all (`plugins/dsh-notify-ios`). Subagent turns: only a
//  session-tree root is reported. Repeats: each approval and question carries a
//  stable dedupe key, and the key is withdrawn when the thing is settled, so a
//  banner cannot be posted twice for one decision while a genuinely new ask still
//  notifies.
//
//  WHAT IS IN A NOTIFICATION
//  -------------------------
//  A short title (the session title, or `DSH`) and one short sentence. The body
//  never contains a token, a key, a full path or a command: the plugin does not
//  send them, and `scrub` removes anything that looks like one anyway. The
//  `threadIdentifier` is the session id, so notifications about one conversation
//  group instead of stacking as unrelated banners.
//
//  GATING
//  ------
//  Always on. This is the feature, not a measurement hook. The switches live in
//  `UserDefaults` and default to on; a user who has never touched them sees all
//  four. See `NotificationSettingsView` and `Settings.bundle` for where they are
//  shown.
//

import Foundation
import UIKit
import UserNotifications
import WebKit

/// The four things a user can be told about while the app is hidden.
enum NotifyKind: String, CaseIterable {
    case done
    case error
    case approval
    case question

    /// The switch's label.
    var label: String {
        switch self {
        case .done: return "一轮做完"
        case .error: return "出错"
        case .approval: return "等批准"
        case .question: return "AI 提问"
        }
    }

    /// What the switch does, in one line.
    var detail: String {
        switch self {
        case .done: return "这一轮跑完时通知我"
        case .error: return "这一轮出错时通知我"
        case .approval: return "有操作等我批准时通知我"
        case .question: return "AI 向我提问时通知我"
        }
    }

    /// The `UserDefaults` key.
    ///
    /// Doubles as the key in `Settings.bundle/Root.plist`, which is what makes the
    /// iOS Settings app and this app edit the same value rather than two copies of
    /// it. Prefixed so it cannot collide with another step's flag.
    var defaultsKey: String { "DSHPortENotify." + rawValue }
}

/// Which switches are on, persisted.
///
/// A separate type rather than three loose `UserDefaults` reads in three places,
/// which is how one of them ends up defaulting the wrong way.
enum NotifySettings {
    /// Absent means on: the task asks for all four on by default, and
    /// `UserDefaults.bool(forKey:)` answers `false` for an absent key — the
    /// opposite of the requirement — so absence is checked explicitly.
    static func isEnabled(_ kind: NotifyKind) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: kind.defaultsKey) != nil else { return true }
        return defaults.bool(forKey: kind.defaultsKey)
    }

    static func set(_ kind: NotifyKind, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: kind.defaultsKey)
    }

    static var anyEnabled: Bool { NotifyKind.allCases.contains { isEnabled($0) } }

    /// Every switch, as one dictionary, for the status file and the report.
    static func snapshot() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for kind in NotifyKind.allCases { out[kind.rawValue] = isEnabled(kind) }
        return out
    }
}

/// Everything this class observed, written into the app's status file.
///
/// Two kinds of entry on purpose. `delivered` is the positive evidence a banner
/// exists; `suppressed` is the counter-evidence, with the reason — without it "no
/// notification appeared" cannot be told apart from "the feature is dead", which is
/// the measurement mistake REPORT-13 §4 was written about.
struct NotificationReport: Codable {
    var switches: [String: Bool] = [:]
    /// `notDetermined`, `denied`, `authorized`, `provisional`, `ephemeral`.
    var authorization = "未询问"
    /// How many times the system prompt was actually requested. Must stay 0 or 1 per
    /// launch: re-prompting an app the system has already answered for is what the
    /// task forbids and what a denial makes pointless.
    var authorizationRequests = 0
    var delivered: [[String: String]] = []
    var suppressed: [[String: String]] = []
    var withdrawn: [String] = []
    var taps: [[String: String]] = []
    /// A tap whose navigation has not been confirmed yet.
    var pendingOpenSessionId: String?
    /// What the last navigation attempt reported, in words.
    var lastNavigation = ""
    /// Whether the scene was active at the moment of the last delivery decision.
    var lastSceneActive: Bool?
}

/// The earliest possible hook for a notification tap.
///
/// WHY THIS IS NOT PART OF `NotificationBridge`. When a notification tap LAUNCHES
/// the app, `UNUserNotificationCenter` delivers the response to whatever object is
/// its delegate at the end of launch. `NotificationBridge` is `@MainActor` and is
/// started from the first view's `onAppear`, which is after that point — a delegate
/// installed there would miss the launch tap. So the delegate is installed from
/// `DSHPortCApp.init()`, which runs earlier, and this type exists to be a delegate
/// that can be installed before any view exists. It holds the tap until the bridge
/// installs its handler.
final class NotificationTapRelay: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTapRelay()

    /// Set by `NotificationBridge.start()`, on the main actor.
    private var handler: (@MainActor (String, String) -> Void)?
    /// Taps that arrived before a handler existed. A small array, not a single slot:
    /// two notifications can be tapped across two launches of the app.
    private var pending: [(String, String)] = []
    private let lock = NSLock()

    /// Install the delegate. Idempotent, and safe to call before any view exists.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Hand every delivery to the bridge and replay whatever arrived first.
    func adopt(_ handler: @escaping @MainActor (String, String) -> Void) {
        self.handler = handler
        let replay: [(String, String)] = lock.withLock {
            let copy = pending
            pending.removeAll()
            return copy
        }
        for (sessionId, kind) in replay {
            Task { @MainActor in handler(sessionId, kind) }
        }
    }

    private func record(sessionId: String, kind: String) {
        let callback = lock.withLock { () -> (@MainActor (String, String) -> Void)? in
            if handler == nil { pending.append((sessionId, kind)); return nil }
            return handler
        }
        guard let callback else { return }
        Task { @MainActor in callback(sessionId, kind) }
    }

    /// Present the banner even if the app came forward between the decision and the
    /// delivery. The bridge does not post in the foreground, so this only ever
    /// covers that race — and presenting it is the honest answer, because the
    /// request was made while the user was elsewhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        record(
            sessionId: info["sessionId"] as? String ?? "",
            kind: info["kind"] as? String ?? ""
        )
        completionHandler()
    }
}

@MainActor
final class NotificationBridge {
    static let shared = NotificationBridge()

    /// Kept as a property rather than re-fetched: the center is a singleton, but
    /// holding it makes "one object talks to the system" visible in one place.
    private let center = UNUserNotificationCenter.current()

    private(set) var report = NotificationReport()
    private var started = false
    /// True once `requestAuthorization` has been called in this process, whether or
    /// not the user has answered yet.
    private var requestedThisLaunch = false
    /// Delivered notifications not yet withdrawn, by the plugin's dedupe key.
    private var deliveredByKey: Set<String> = []
    /// A tap whose navigation has not been completed.
    private var pendingOpen: String?
    /// The scene's activation state as last observed.
    private var sceneIsActive = true
    /// The system's answer about authorization, cached.
    ///
    /// WHY CACHED RATHER THAN ASKED AT DELIVERY TIME. `notificationSettings()` is an
    /// async round trip to the system, and the moment a notification has to be
    /// decided is the moment the app has just been backgrounded — where the first
    /// measurement of this feature hung: the `Task` awaited the reply, the process was
    /// suspended before it came back, and the request was neither delivered nor
    /// recorded. A cached value makes the decision synchronous, so it happens (and is
    /// written to the log) even if the process is about to stop.
    ///
    /// The cache is refreshed everywhere the system's answer can change: at start, on
    /// every `requestAuthorization` reply, and after each delivery attempt (which is
    /// also where a user who has just changed the setting in the Settings app is
    /// noticed).
    private var cachedAuthorization: UNAuthorizationStatus = .notDetermined

    // MARK: - Wiring

    /// Install the delegate handler and subscribe to the scene's transitions.
    /// Called once from the app's `onAppear`: one line, no state of its own in that
    /// view, so this file stays mergeable while other steps rewrite it.
    func start() {
        guard !started else { return }
        started = true
        NotificationTapRelay.install()
        NotificationTapRelay.shared.adopt { [weak self] sessionId, kind in
            self?.handleTap(sessionId: sessionId, kind: kind)
        }
        // The seed value, read rather than assumed: an app launched by a
        // notification tap starts in the background, and believing it is in the
        // foreground would suppress the first notification of the new process.
        sceneIsActive = UIApplication.shared.applicationState == .active
        report.lastSceneActive = sceneIsActive

        let notifications = NotificationCenter.default
        notifications.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteScene(active: true) }
        }
        notifications.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteScene(active: false) }
        }

        applyDebugSwitchOverrides()
        report.switches = NotifySettings.snapshot()

        // Read the current authorization WITHOUT asking for it. Asking at launch is
        // exactly the prompt the task says must not appear.
        //
        // Retried with a delay, because the first read during launch was measured never
        // to call back (see `readAuthorization`); the answer is also re-read at every
        // `turn-start`, which is the moment that actually decides a delivery.
        Task { @MainActor in
            // Read immediately, then once more shortly after: measured, a read issued in
            // `onAppear` sometimes never calls back at all while the scene is still
            // settling, and a single delayed read lost the race against a launch whose
            // first turn started within 6 s. Two reads cost nothing and both write the
            // same field.
            await self.readAuthorization()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.readAuthorization()
        }
        // A dump on demand, so the acceptance can record what the system says is
        // delivered without guessing from a screenshot. Gated on a launch argument;
        // a normal launch never reaches it.
        if dumpEnabled {
            dumpDelivered(reason: "launch")
        }
        // A tap simulated from a launch argument, for the acceptance path that has
        // no way to press a real banner: `xcodebuild` cannot see a custom device set,
        // so an XCUITest tap and a `simctl` install cannot be combined in one run.
        // This feeds the SAME `handleTap` a real tap reaches, so what it proves is the
        // navigation, not the tap — the tap itself is covered by the XCUITest run.
        if let sessionId = UserDefaults.standard.string(forKey: "DSHPortESimulateNotifyTap"), !sessionId.isEmpty {
            emit("dshportc: notify simulating a tap on \(sessionId) (debug hook)")
            handleTap(sessionId: sessionId, kind: "done")
        }
        emit("dshportc: notify bridge started (\(describeSwitches()))")
        writeReport()
    }

    /// Feed one `DSHPORTC_NOTIFY {...}` payload from Node's stdout.
    ///
    /// Malformed input is ignored rather than fatal, for the same reason the busy
    /// bridge's parser is: this runs on the dispatcher that also reads the launch
    /// URL, and a parse error there must not be able to take that down.
    func noteBridgeLine(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String
        else {
            emit("dshportc: notify ignored a malformed bridge line")
            return
        }
        switch kind {
        case "turn-start":
            // TWO things happen here, in this order.
            //
            // 1. Read the system's current answer and CACHE it, waiting for the reply.
            //    This is the moment with time to spare: a turn has just started, so the
            //    notification it produces is seconds or minutes away, and the app is in
            //    the foreground (or one step from it). Measured: `getNotificationSettings`
            //    called from `start()` — before the scene had settled — never called
            //    back at all, so `authorization` stayed "未询问" forever and every
            //    delivery was suppressed for "authorization not yet granted" even on a
            //    device that had granted it. Waiting here, at a point where waiting is
            //    free, is what makes the cached answer trustworthy.
            // 2. Ask for permission if it has never been asked. A denial is final for
            //    the process and remembered by the system, so this cannot loop.
            Task { @MainActor in
                await self.readAuthorization()
                self.requestAuthorizationIfNeeded()
            }
        case "dismiss":
            let key = object["key"] as? String ?? ""
            if !key.isEmpty { withdraw(key: key) }
        case "done", "error", "approval", "question":
            deliver(
                kind: kind,
                sessionId: object["sessionId"] as? String ?? "",
                title: object["title"] as? String ?? "",
                body: object["body"] as? String ?? "",
                key: object["key"] as? String ?? ""
            )
        default:
            break
        }
    }

    // MARK: - Debug hooks

    /// Write switches into `UserDefaults` once, from a launch argument.
    ///
    /// WHY THIS EXISTS. The acceptance has to show two things that a tap-driven run
    /// cannot show on its own: that a switch left off really suppresses only that
    /// one kind, and that the state survives a restart. Driving the sheet with a
    /// finger proves the sheet works, but it also makes the run depend on the
    /// sidebar, a drawer and a long press, so a failure would be ambiguous. This hook
    /// writes the SAME keys the sheet writes, into the same persistent domain, so the
    /// run after it is an ordinary launch with no arguments at all — which is exactly
    /// the claim "重启后开关还在" makes.
    ///
    /// Syntax: `-DSHPortESetNotify done=off,error=on,approval=on,question=on`. Gated
    /// on the argument's presence, so a normal launch can never reach it.
    private func applyDebugSwitchOverrides() {
        guard let spec = UserDefaults.standard.string(forKey: "DSHPortESetNotify"), !spec.isEmpty else { return }
        var applied: [String] = []
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let kind = NotifyKind(rawValue: parts[0]) else { continue }
            let on = ["on", "1", "true", "yes"].contains(parts[1].lowercased())
            NotifySettings.set(kind, enabled: on)
            applied.append("\(parts[0])=\(on ? "on" : "off")")
        }
        if !applied.isEmpty {
            emit("dshportc: notify switches set by launch argument: \(applied.joined(separator: " "))")
        }
    }

    /// True when this launch wants the system's delivered list written out.
    private var dumpEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortENotifyDump") == 1
    }

    /// Ask the system what it currently has delivered, and write that to a file.
    ///
    /// WHY THE SYSTEM AND NOT THIS CLASS. `report.delivered` is what this class
    /// ASKED to deliver; `getDeliveredNotifications` is what the system actually
    /// holds. The acceptance criterion is about the second one — a request that was
    /// accepted and then silently coalesced or dropped would look identical in the
    /// first. The dump therefore also names the source, so a reader can tell which
    /// question a number answers.
    ///
    /// The file is `Documents/DSHPortC-notifications.json`, a list of dumps newest
    /// last, so several dumps per launch are distinguishable.
    func dumpDelivered(reason: String) {
        center.getDeliveredNotifications { [weak self] delivered in
            Task { @MainActor in
                guard let self else { return }
                let rows: [[String: Any]] = delivered.map { item in
                    let content = item.request.content
                    return [
                        "identifier": item.request.identifier,
                        "title": content.title,
                        "body": content.body,
                        "thread": content.threadIdentifier,
                        "sessionId": content.userInfo["sessionId"] as? String ?? "",
                        "kind": content.userInfo["kind"] as? String ?? "",
                        "key": content.userInfo["key"] as? String ?? "",
                        "date": ISO8601DateFormatter().string(from: item.date),
                    ]
                }
                self.appendDump(reason: reason, delivered: rows)
            }
        }
    }

    private func appendDump(reason: String, delivered: [[String: Any]]) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("DSHPortC-notifications.json")
        var dumps: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previous = existing["dumps"] as? [[String: Any]] {
            dumps = previous
        }
        dumps.append([
            "reason": reason,
            "at": ISO8601DateFormatter().string(from: Date()),
            "authorization": report.authorization,
            "sceneActive": sceneIsActive,
            "switches": report.switches,
            "delivered": delivered,
        ])
        let payload: [String: Any] = ["dumps": dumps]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
        emit("dshportc: notify dumped \(delivered.count) delivered notification(s) (\(reason))")
        publishStatusCopy()
    }

    // MARK: - A reclaim with work in flight

    /// Tell the user the turn was paused by the system, filed under the ERROR switch.
    ///
    /// WHY THIS IS NOT A PLUGIN EVENT. The plugin only sees the session's durable
    /// events, and a reclaim produces none: the process is suspended, the turn stays
    /// open, and `turn/end` never arrives. So the one honest observer is
    /// `BackgroundContinuation.handleExpiration()`, which is where this is called
    /// from. The notification is therefore built here rather than reported from Node.
    ///
    /// It goes through the same gates as every other notification (switch, scene,
    /// authorization), which is what makes "归入出错这个开关" true rather than nominal,
    /// and it arrives after the app has already been backgrounded, which is the only
    /// moment it can be useful.
    func noteBackgroundExpiration(turn: Int, step: Int) {
        // One key per reclaim, derived from the turn it interrupted: a second
        // reclaim of the SAME turn is the same news, and two banners saying it
        // would be noise. A different turn is a different key.
        let key = "expiry:turn\(turn):step\(step)"
        backgroundPauseKey = key
        deliver(
            kind: NotifyKind.error.rawValue,
            sessionId: "",
            title: "",
            body: "任务被系统暂停，回到 App 继续",
            key: key
        )
    }

    /// The user came back, or the turn ended before the freeze landed. Either way
    /// "come back to continue" is no longer true.
    func withdrawBackgroundPause() {
        guard let key = backgroundPauseKey else { return }
        backgroundPauseKey = nil
        withdraw(key: key)
    }

    // MARK: - Permission
    // MARK: - Permission

    /// Ask once, and only while there is a turn to talk about.
    ///
    /// Three separate reasons not to ask again: this process already asked; the
    /// user turned all four switches off, in which case the prompt would be asking
    /// for permission to do nothing; and — the system's own answer, read below — a
    /// `denied` status, which no further prompt can change. The first two are
    /// checked here, the third in `deliver`.
    private func requestAuthorizationIfNeeded() {
        guard !requestedThisLaunch else { return }
        guard NotifySettings.anyEnabled else {
            emit("dshportc: notify all switches off, so no system prompt was requested")
            return
        }
        requestedThisLaunch = true
        report.authorizationRequests += 1
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // Recorded, not thrown: the caller is the line dispatcher.
                    self.emit("dshportc: notify authorization request failed: \(error.localizedDescription)")
                }
                self.emit("dshportc: notify authorization requested -> granted=\(granted)")
                self.center.getNotificationSettings { settings in
                    Task { @MainActor in self.noteAuthorization(settings.authorizationStatus) }
                }
            }
        }
    }

    /// Read the system's answer and cache it, waiting for the reply.
    ///
    /// The `await` is the point: `getNotificationSettings` is a round trip to the
    /// notification daemon, and a fire-and-forget call made during launch was measured
    /// never to call back. Awaiting it at a moment with time to spare is what turns the
    /// cache into a usable answer.
    func readAuthorization() async {
        let settings = await center.notificationSettings()
        noteAuthorization(settings.authorizationStatus)
    }

    private func noteAuthorization(_ status: UNAuthorizationStatus) {
        cachedAuthorization = status
        report.authorization = Self.describe(status)
        emit("dshportc: notify authorization now \(report.authorization)")
        writeReport()
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// The status in the words the settings sheet shows.
    var authorizationExplanation: String {
        switch report.authorization {
        case "authorized", "provisional", "ephemeral":
            return "系统通知已允许"
        case "denied":
            return "系统通知已关闭"
        case "notDetermined":
            return "还没有请求过系统通知授权（第一轮开始时才会请求）"
        default:
            return "系统通知状态未知"
        }
    }

    /// Whether the app can post, from the cached status.
    ///
    /// Synchronous on purpose — see `cachedAuthorization`. The tuple's second element
    /// is the sentence a suppression is recorded with, so "nothing appeared" always
    /// carries the reason it did not.
    private func postable() -> (Bool, String) {
        switch cachedAuthorization {
        case .authorized, .provisional, .ephemeral:
            return (true, "")
        case .denied:
            return (false, "系统通知已被拒绝")
        case .notDetermined:
            return (false, "尚未获得系统通知授权")
        @unknown default:
            return (false, "系统通知状态未知")
        }
    }

    /// Re-read the system's answer in the background, for the next decision.
    private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.noteAuthorization(settings.authorizationStatus) }
        }
    }

    // MARK: - Delivering

    /// The three gates, in the order a person would state them.
    ///
    /// Synchronous ones first — the switch and the scene — so the negative cases the
    /// acceptance measures are decided without an `await` and are recorded even
    /// while the process is about to be suspended.
    private var backgroundPauseKey: String?

    private func deliver(kind: String, sessionId: String, title: String, body: String, key: String) {
        guard let notifyKind = NotifyKind(rawValue: kind) else { return }
        report.lastSceneActive = sceneIsActive
        guard NotifySettings.isEnabled(notifyKind) else {
            suppress(kind: kind, sessionId: sessionId, key: key, reason: "开关已关（\(notifyKind.label)）")
            return
        }
        guard !sceneIsActive else {
            suppress(kind: kind, sessionId: sessionId, key: key, reason: "App 在前台，不发")
            return
        }
        let (allowed, why) = postable()
        guard allowed else {
            suppress(kind: kind, sessionId: sessionId, key: key, reason: why)
            // The cached status may be stale — the user could have granted or revoked
            // the permission in the Settings app since the last read. Refresh for the
            // next decision; this one is already recorded as suppressed, which is
            // what actually happened.
            refreshAuthorization()
            return
        }
        Task { @MainActor in
            await post(kind: kind, sessionId: sessionId, title: title, body: body, key: key)
        }
    }

    private func post(kind: String, sessionId: String, title: String, body: String, key: String) async {
        let content = UNMutableNotificationContent()
        let scrubbedTitle = Self.scrub(title)
        content.title = scrubbedTitle.isEmpty ? "DSH" : scrubbedTitle
        content.body = Self.scrub(body)
        content.sound = .default
        if !sessionId.isEmpty { content.threadIdentifier = sessionId }
        content.userInfo = ["sessionId": sessionId, "kind": kind, "key": key]

        let identifier = key.isEmpty ? UUID().uuidString : key
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            if !key.isEmpty { deliveredByKey.insert(key) }
            report.delivered.append([
                "kind": kind,
                "title": content.title,
                "body": content.body,
                "key": key,
                "sessionId": sessionId,
                "thread": content.threadIdentifier,
            ])
            emit("dshportc: notify delivered \(kind) title=\(content.title) body=\(content.body)")
            if dumpEnabled { dumpDelivered(reason: "after-delivery") }
            refreshAuthorization()
        } catch {
            suppress(kind: kind, sessionId: sessionId, key: key, reason: "投递失败：\(error.localizedDescription)")
            return
        }
        writeReport()
    }

    /// Withdraw a delivered notification whose reason is gone.
    ///
    /// This is the "answered it in the app" half: an approval the user has just
    /// allowed or rejected must not keep sitting in the notification centre as
    /// something still waiting. Reached from the plugin's `dismiss` line, which
    /// fires on `approval/decided` and on the `tool/result` that answers a question.
    private func withdraw(key: String) {
        guard deliveredByKey.contains(key) else { return }
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
        deliveredByKey.remove(key)
        report.withdrawn.append(key)
        emit("dshportc: notify withdrew \(key)")
        writeReport()
        if dumpEnabled { dumpDelivered(reason: "after-withdraw") }
    }

    private func suppress(kind: String, sessionId: String, key: String, reason: String) {
        report.suppressed.append([
            "kind": kind,
            "reason": reason,
            "sessionId": sessionId,
            "key": key,
        ])
        emit("dshportc: notify suppressed \(kind): \(reason)")
        writeReport()
    }

    // MARK: - Foreground state

    private func noteScene(active: Bool) {
        sceneIsActive = active
        report.lastSceneActive = active
        if active {
            // Coming back is when a still-delivered banner about this app stops
            // being useful. The settled cases are withdrawn by the plugin's
            // `dismiss` lines; this is the third case — the user simply came back.
            emit("dshportc: notify scene active")
            if dumpEnabled { dumpDelivered(reason: "foreground") }
        }
        writeReport()
    }

    // MARK: - Taps

    /// Route a notification tap to the session it came from.
    ///
    /// The three states differ only in what exists when the tap lands:
    ///
    ///   * running and backgrounded — the system activates the scene and the web
    ///     view is alive, so navigation can be attempted immediately;
    ///   * suspended — the tap resumes the process, the web view is alive but the
    ///     page may need a moment;
    ///   * killed — the system launches the app, Node starts from scratch and the
    ///     page does not exist yet, so the id is remembered here and consumed when
    ///     the page reports ready.
    ///
    /// The id is kept until a navigation actually succeeds, so a tap is never lost,
    /// and repeating it is idempotent.
    func handleTap(sessionId: String, kind: String) {
        report.taps.append(["sessionId": sessionId, "kind": kind])
        guard !sessionId.isEmpty else {
            report.lastNavigation = "通知里没有会话 id，只把 App 打开"
            emit("dshportc: notify tapped with no session id")
            writeReport()
            return
        }
        pendingOpen = sessionId
        report.pendingOpenSessionId = sessionId
        emit("dshportc: notify tapped for session \(sessionId)")
        // Withdraw the banner that was tapped: the user has seen it, and leaving it
        // in the centre after acting on it is the same mistake as leaving a settled
        // approval there.
        withdraw(key: notificationKey(forKind: kind, sessionId: sessionId))
        writeReport()
        Task { @MainActor in await self.consumePendingOpen() }
    }

    /// Called when the web page says its first paint is in. Consumes a tap that
    /// arrived before there was a page to navigate.
    func pageDidBecomeReady() {
        guard pendingOpen != nil else { return }
        Task { @MainActor in await self.consumePendingOpen() }
    }

    /// Try to open the remembered session, retrying while the page settles.
    ///
    /// WHY RETRY RATHER THAN ONE CALL. The page's sidebar is a drawer on a phone and
    /// the session rows only exist in the DOM once it is open, so the first attempt
    /// legitimately reports "drawer opening" and the row appears a moment later. A
    /// single attempt would report failure for a navigation that was working.
    private func consumePendingOpen() async {
        guard let sessionId = pendingOpen else { return }
        var lastResult = "unavailable"
        for attempt in 1...12 {
            lastResult = await NotificationNavigation.shared.open(sessionId)
            switch lastResult {
            case "pressed", "already-selected", "reloading":
                pendingOpen = nil
                report.pendingOpenSessionId = nil
                report.lastNavigation = "已跳到会话 \(sessionId)（\(lastResult)，第 \(attempt) 次尝试）"
                emit("dshportc: notify navigation \(lastResult) for \(sessionId) on attempt \(attempt)")
                writeReport()
                return
            default:
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        // Still remembered: the next `pageDidBecomeReady` or the next tap tries
        // again. Saying "failed" without keeping the id would lose the tap.
        report.lastNavigation = "页面还没准备好跳到会话 \(sessionId)（最后一次：\(lastResult)），已记下"
        emit("dshportc: notify navigation deferred for \(sessionId) (\(lastResult))")
        writeReport()
    }

    private func notificationKey(forKind kind: String, sessionId: String) -> String {
        // The tap carries the request identifier in `userInfo.key`; recomputing it
        // from the kind and session would be wrong for approvals, whose key is the
        // approval id. This lookup exists only for the "withdraw what was tapped"
        // path, and the report records the real key when the tap arrives.
        guard let entry = report.delivered.last(where: { $0["sessionId"] == sessionId && $0["kind"] == kind })
        else { return "" }
        return entry["key"] ?? ""
    }

    // MARK: - Redaction

    /// Remove anything that looks like a secret or a location.
    ///
    /// A second line of defence, not the first: the plugin sends one of a handful of
    /// fixed sentences. But a notification is drawn on top of another app, and a
    /// path or a token in one is the kind of thing only noticed after someone else
    /// has read it. `NodeRunner.redact` already knows the launch-token and guest
    /// channel token shapes; this adds the two shapes a body could plausibly
    /// acquire — an absolute path and a credential-looking word.
    static func scrub(_ text: String) -> String {
        var out = NodeRunner.redact(text)
        out = out.replacingOccurrences(
            of: "(?:/Users|/var|/private|/Volumes|/Applications|/tmp|/workspace)/[^\\s,，。；;、]*",
            with: "…",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\\b(?:sk|pk|Bearer)[-_A-Za-z0-9.]{8,}",
            with: "…",
            options: [.regularExpression, .caseInsensitive]
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Observability

    private func describeSwitches() -> String {
        NotifyKind.allCases
            .map { "\($0.rawValue)=\(NotifySettings.isEnabled($0) ? "on" : "off")" }
            .joined(separator: " ")
    }

    /// Called by the settings sheet after a switch changes, so the status file and
    /// the log carry the new state without waiting for the next event.
    func refreshSwitchSnapshot(reason: String) {
        report.switches = NotifySettings.snapshot()
        emit("dshportc: notify switches changed (\(reason)): \(describeSwitches())")
        writeReport()
    }

    /// `deliveredAt` is stamped by `NodeRunner`, which owns the status file.
    private func writeReport() {
        NodeRunner.shared.noteNotificationReport(report)
        publishStatusCopy()
    }

    /// Copy the notification section into a file the UI test process can read.
    ///
    /// WHY A COPY EXISTS. XCUITest runs in its own process, so it cannot open this
    /// app's Documents directory; the app's status file is the only place the
    /// navigation result is recorded, and an assertion about "did the tap route to the
    /// right session" would otherwise have to be inferred from what is on screen. The
    /// copy is written into the app's own temporary directory, which the test runner
    /// shares, and it holds the notification section only — no session ids beyond the
    /// ones already in the log, no tokens, no paths.
    ///
    /// Gated on the dump flag, so a normal launch writes nothing extra.
    private func publishStatusCopy() {
        guard dumpEnabled else { return }
        let payload: [String: Any] = ["notifications": [
            "authorization": report.authorization,
            "authorizationRequests": report.authorizationRequests,
            "switches": report.switches,
            "delivered": report.delivered,
            "suppressed": report.suppressed,
            "withdrawn": report.withdrawn,
            "taps": report.taps,
            "lastNavigation": report.lastNavigation,
            "pendingOpenSessionId": report.pendingOpenSessionId as Any,
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("step16-status.json")
        try? data.write(to: url, options: .atomic)
    }

    private func emit(_ line: String) {
        NodeRunner.shared.noteBackgroundLine(line)
    }
}

// MARK: - Driving the page from a host-side acceptance run

/// Runs one JavaScript expression at a time, on request from a host-side script.
///
/// WHY A COMMAND FILE AND NOT A LAUNCH ARGUMENT. Three of the acceptance steps need
/// to act on an app that is ALREADY RUNNING: answer an approval after the ask has
/// been observed, press stop in the middle of a turn, read back which session the
/// page has selected. A launch argument is read once at start, so it cannot reach
/// those moments; relaunching to deliver it would destroy the very state being
/// measured. So the channel is a file in the app's own Documents directory: the
/// script writes `{id, script}`, this driver evaluates it in the app's own web view
/// and writes `{id, result}` back.
///
/// WHY IT IS NOT PART OF THE FEATURE. Nothing in `NotificationBridge` depends on it,
/// and it runs only when launched with `-DSHPortENotifyDrive 1`. A normal launch
/// neither polls nor reads the file.
///
/// WHAT IT PROVES AND WHAT IT DOES NOT. It proves the app's reaction to a press:
/// that answering an approval withdraws the delivered notification, that stopping a
/// turn produces no notification, that a navigation lands on the right session. It
/// does NOT prove the press itself is reachable by a finger — that is XCUITest's
/// job, and REPORT-16 keeps the two apart.
///
/// The file protocol, deliberately tiny:
///   in  `Documents/DSHPortENotifyCommand.json`  = {"id": "<string>", "script": "<js>"}
///   out `Documents/DSHPortENotifyResult.json`   = {"id": "<string>", "result": "<string>"}
/// An `id` already answered is not re-run, so a leftover file cannot repeat an action.
@MainActor
final class NotificationActionDriver {
    static let shared = NotificationActionDriver()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortENotifyDrive") == 1
    }

    private weak var webView: WKWebView?
    private var timer: Timer?
    private var answered: Set<String> = []
    private var busy = false

    private var commandURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSHPortENotifyCommand.json")
    }

    private var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSHPortENotifyResult.json")
    }

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        // Re-arm on every registration, and make the timer's own liveness observable.
        //
        // WHY: `isEnabled` is read from launch arguments, and `simctl launch` on a running
        // app writes the argument domain again — so a resume that omits `-DSHPortENotifyDrive`
        // turns `isEnabled` false while the timer keeps firing against a `webView` that
        // SwiftUI rebuilt. Measured: after such a resume every command timed out, with the
        // channel's own log line appearing only once at first launch. Re-arming here (and
        // logging it) is what makes "the channel is alive" checkable rather than assumed.
        timer?.invalidate()
        timer = nil
        NodeRunner.shared.noteBackgroundLine("dshportc: notify drive channel armed")
        // 0.4 s: fast enough that a check's own timing dominates, slow enough that
        // polling is invisible next to the model turn it is measuring.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
    }

    private func poll() {
        guard !busy, let webView else { return }
        guard let data = try? Data(contentsOf: commandURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              !answered.contains(id)
        else { return }
        answered.insert(id)
        busy = true

        // A native action, for the one thing JavaScript cannot do: deliver a
        // notification tap. A real tap is a `UNNotificationResponse`, and the only
        // honest way to reach `handleTap` from a host-side script is to call it with
        // the id a tap would carry. The press on a real banner is still XCUITest's
        // job; this drives the navigation behind it.
        if let sessionId = object["tap"] as? String {
            NotificationBridge.shared.handleTap(sessionId: sessionId, kind: "done")
            let payload: [String: Any] = ["id": id, "result": "tap-dispatched:\(sessionId)"]
            if let out = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? out.write(to: self.resultURL, options: .atomic)
            }
            NodeRunner.shared.noteBackgroundLine("dshportc: notify drive \(id) -> tap-dispatched")
            busy = false
            return
        }

        guard let script = object["script"] as? String else {
            busy = false
            return
        }
        Task { @MainActor in
            var result = "no-result"
            do {
                let value = try await webView.evaluateJavaScript(script)
                if let text = value as? String {
                    result = text
                } else if let value {
                    result = String(describing: value)
                } else {
                    result = "nil"
                }
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            let payload: [String: Any] = ["id": id, "result": result]
            if let out = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? out.write(to: self.resultURL, options: .atomic)
            }
            NodeRunner.shared.noteBackgroundLine("dshportc: notify drive \(id) -> \(result)")
            self.busy = false
        }
    }
}

// MARK: - Navigating to a session

/// Asks the DSH web page to select one session.
///
/// WHY THERE IS NO URL FOR THIS. The page's selection is a client-side store
/// (`uiWorkspace`'s `selection`, persisted under `dsh.sessions.current`) written by
/// `replaceMain`, and the web app keeps no route that names a session — the only
/// query parameters it reads belong to the subagent panel. So a tap is turned into
/// the same thing a click on a sidebar row produces: a press on
/// `[data-row-key="session:<id>"]`, the identity `ui-workspace` puts on every row
/// and the same selector `UIDriver` already uses to drive the sidebar. No `payload/`
/// change, and no invented deep link that would break on the next release.
///
/// The fallback order is the least disruptive first: the row is already rendered →
/// press it; the drawer is closed → open it and press; the row is not in the DOM at
/// all (another workspace) → write the persisted selection and reload, which is the
/// path `uiWorkspace.restoreSelection` reads on boot.
@MainActor
final class NotificationNavigation {
    static let shared = NotificationNavigation()

    private weak var webView: WKWebView?

    func register(_ webView: WKWebView) { self.webView = webView }

    /// @returns what the page said: `pressed`, `already-selected`, `reloading`,
    ///   `drawer-opening`, `unreachable`, or `unavailable` without a web view.
    func open(_ sessionId: String) async -> String {
        guard let webView else { return "unavailable" }
        do {
            let result = try await webView.evaluateJavaScript(Self.pressSessionRowScript(sessionId: sessionId))
            return result as? String ?? "unreachable"
        } catch {
            return "unreachable"
        }
    }

    /// The JavaScript that selects a session.
    static func pressSessionRowScript(sessionId: String) -> String {
        // The id comes from a session header and is a UUID, but it is interpolated
        // into source: quoting it properly costs one line and removes the question.
        let quoted = sessionId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          const wanted = '\(quoted)';
          const key = 'session:' + wanted;
          const press = (el) => {
            el.scrollIntoView({ block: 'nearest' });
            for (const type of ['pointerdown', 'pointerup', 'click']) {
              el.dispatchEvent(new PointerEvent(type, {
                bubbles: true, cancelable: true, pointerType: 'touch',
                pointerId: 1, isPrimary: true,
              }));
            }
          };
          const row = Array.from(document.querySelectorAll('[data-row-key]'))
            .find((el) => (el.getAttribute('data-row-key') || '') === key);
          if (row !== null && row !== undefined) {
            if (row.getAttribute('aria-selected') === 'true') return 'already-selected';
            press(row);
            return 'pressed';
          }
          // The drawer may simply be closed: on a phone the session list is a
          // drawer, and the rows are not in the DOM until it opens.
          const labels = ['打开侧边栏', 'Open sidebar'];
          for (const button of Array.from(document.querySelectorAll('button,[role="button"]'))) {
            const label = button.getAttribute('aria-label') || '';
            const text = (button.innerText || '').trim();
            if (labels.some((w) => label.indexOf(w) >= 0 || text === w)) {
              for (const type of ['pointerdown', 'pointerup', 'click']) {
                button.dispatchEvent(new PointerEvent(type, {
                  bubbles: true, cancelable: true, pointerType: 'touch',
                  pointerId: 1, isPrimary: true,
                }));
              }
              return 'drawer-opening';
            }
          }
          // The row is not reachable because the session belongs to a workspace the
          // sidebar is not showing. Write the persisted selection and reload: the
          // Workspace service reads exactly this key on boot
          // (`createSnapshotStore(..., { persist: { name: 'dsh.sessions.current' } })`).
          try {
            localStorage.setItem('dsh.sessions.current', JSON.stringify({ sessionId: wanted }));
            location.reload();
            return 'reloading';
          } catch (e) {
            return 'unreachable';
          }
        })();
        """
    }
}
