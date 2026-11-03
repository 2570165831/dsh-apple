//
//  Step15Probe.swift
//  DSHPortC
//
//  Step 15's measurement hook: the interaction questions step 11 left behind,
//  plus the send-mode check the user asked for by name.
//
//  WHY IT EXISTS
//  ---------------
//  Every question in this step is about a state that only exists while the app
//  runs: whether an IME composition followed by Return sends a message, how many
//  presses it takes to reach a session row, whether the native bands and the
//  page agree on dark mode, whether a long code line widens the document. None
//  of it is readable from the source, and the DOM is the only witness that sees
//  exactly what a person sees.
//
//  So this records the page's own numbers, at named moments, into a JSON file.
//  It decides nothing and asserts nothing; the comparison and the verdicts live
//  in REPORT-15.md, where a reader can check them against the raw numbers.
//
//  GATING
//  ------
//  Nothing here runs unless the app is launched with `-DSHPortEStep15 1`, so a
//  normal launch never reaches this code.
//
//  THE `eval` ACTION
//  -----------------
//  A DOM experiment that needs a new measurement means a new build (the project
//  is generated from a source glob, and every build is minutes). To keep the
//  iteration on the page's own facts cheap, `-DSHPortEStep15Action eval` reads a
//  JavaScript file out of the app's own Documents directory, evaluates it, and
//  writes what it returned. That file is host-supplied scratch, never shipped,
//  and the action is gated exactly like the rest. The report's FINAL numbers do
//  not come from it: they come from the named actions below, which are fixed
//  scripts a reader can re-run.
//

import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
final class Step15Probe: ObservableObject {
    static let shared = Step15Probe()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEStep15") == 1
    }

    /// Which scripted sequence to run once the page is up.
    ///
    ///   dump        page structure: frame, columns, rail, composer, send control
    ///   safearea    where the web view sits relative to the status bar, and the
    ///               topmost visible page element (the anti-regression assertion)
    ///   ime         IME composition then Return, in WebKit's order, and whether
    ///               a message went out; also what Return does with no IME
    ///   sidebar     session list: presses to open it and switch a session, and
    ///               what a left-edge drag does
    ///   dark        native bands vs page background, in both appearances
    ///   code        a long code block: does it scroll inside itself or widen
    ///               the document
    ///   resume      background for N seconds, then back: page, scroll, draft
    ///   rail        the 56 pt rail: width before/after, and whether the four
    ///               destinations are still reachable
    ///   send        the three send modes while a turn runs: queue, steer,
    ///               interrupt
    ///   tap         two quick taps on two different controls (the swallowed
    ///               second tap step 11 left in place)
    ///
    /// Unrecognised values do nothing, which is the safe default for a hook that
    /// only exists to measure.
    static var action: String {
        UserDefaults.standard.string(forKey: "DSHPortEStep15Action") ?? "dump"
    }

    static var tag: String {
        UserDefaults.standard.string(forKey: "DSHPortEStep15Tag") ?? ""
    }

    /// Seconds a state should wait where the interesting thing is time.
    static var hold: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "DSHPortEStep15Hold")
        return raw > 0 ? raw : 5
    }

    /// Rotate to this orientation before the scripted sequence runs.
    static var orientation: String? {
        let raw = UserDefaults.standard.string(forKey: "DSHPortEStep15Rotate") ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Which appearance to force for a `dark` run: `light`, `dark` or `system`.
    static var appearance: String? {
        let raw = UserDefaults.standard.string(forKey: "DSHPortEStep15Appearance") ?? ""
        return raw.isEmpty ? nil : raw
    }

    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = tag.isEmpty ? "DSHPortE-step15.json" : "DSHPortE-step15-\(tag).json"
        return documents.appendingPathComponent(name)
    }()

    /// When this process started, for the boot timeline.
    ///
    /// Captured by `DSHPortCApp.init`, which runs before any view exists.
    /// Deriving it from `systemUptime` was WRONG — that clock counts from the
    /// DEVICE boot, so the first measurement reported 470 056 seconds since
    /// launch (five and a half days). If the app has not marked the start yet,
    /// the first access falls back to now, and the record says which.
    private static var launchMark: Date?
    static func markLaunch() { if launchMark == nil { launchMark = Date() } }
    static var launchInstant: Date { launchMark ?? Date() }

    private var webView: WKWebView?
    private var started = false
    private var bootScheduled = false
    private var records: [[String: Any]] = []

    // MARK: - Setup

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        append(["event": "registered", "action": Self.action])
    }

    /// Run the scripted sequence named on the command line.
    func runIfConfigured() {
        guard Self.isEnabled, !started else { return }
        started = true
        Task { @MainActor in
            if let wanted = Self.appearance { applyAppearance(wanted) }
            if let wanted = Self.orientation {
                applyOrientation(wanted)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                append(["event": "orientation-requested", "wanted": wanted])
            }
            // The plugin bundles mount after `didFinish`; measuring before the
            // composer exists would record a page with no conversation in it.
            for _ in 0..<40 {
                if let present = await evaluate("document.querySelector('[data-composer-input]') !== null") as? Bool, present { break }
                append(["event": "waiting-for-composer",
                        "page": (await evaluate(Self.pageDumpScript())) ?? "nil"])
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            let ready = (await evaluate("document.querySelector('[data-composer-input]') !== null") as? Bool) ?? false
            append(["event": ready ? "composer-ready" : "composer-never-appeared"])
            if ready { try? await Task.sleep(nanoseconds: 1_500_000_000) }

            switch Self.action {
            case "dump":     await runDump()
            case "safearea": await runSafeArea()
            case "ime":      await runIME()
            case "sidebar":  await runSidebar()
            case "dark":     await runDark()
            case "mismatch": await runMismatch()
            case "code":     await runCode()
            case "resume":   await runResume()
            case "rail":     await runRail()
            case "send":     await runSendModes()
            case "tap":      await runTap()
            case "boot":     await runBoot()
            case "steer":    await runSteerDelivery()
            case "eval":     await runEvalFile()
            default:
                append(["event": "unrecognised-action", "action": Self.action])
            }
            append(["event": "done", "action": Self.action])
        }
    }

    /// Ask the scene to rotate. A request, not an order: step 10 established
    /// that it is refused before the page is up and honoured after, so the
    /// refusal is recorded rather than assumed away.
    private func applyOrientation(_ wanted: String) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return }
        let mask: UIInterfaceOrientationMask = wanted == "landscape" ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            self?.append(["event": "rotation-refused", "wanted": wanted,
                          "error": error.localizedDescription])
        }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func applyAppearance(_ wanted: String) {
        let style: UIUserInterfaceStyle
        switch wanted {
        case "dark": style = .dark
        case "light": style = .light
        default: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
        append(["event": "appearance-forced", "wanted": wanted])
    }

    // MARK: - Sequences

    private func runDump() async {
        await sample(label: "dump")
        try? await Task.sleep(nanoseconds: 800_000_000)
        await sample(label: "dump-settled")
    }

    /// The anti-regression assertion.
    ///
    /// Step 11's first attempt put the page under the status bar, which drew the
    /// conversation title on top of the clock. The rule that stops it coming back
    /// is two-sided and both sides are recorded here: the web view's own y in
    /// window coordinates must be at or below the safe-area top, and the topmost
    /// visible element *inside* the page must not be above the page's own top
    /// edge.
    private func runSafeArea() async {
        await sample(label: "safearea")
        append(["event": "safearea-assertion", "verdict": safeAreaVerdict()])
    }

    /// IME: composition, then Return, in the order WebKit actually delivers it.
    ///
    /// WebKit differs from Chrome here and the difference is exactly the bug: on
    /// composition commit the event order is `compositionend` FIRST and then the
    /// Return `keydown`, at which point `isComposing` is already false and
    /// `keyCode` is 229. A page that only checks `event.isComposing` therefore
    /// sends a message when the user pressed Return to commit pinyin.
    ///
    /// So this dispatches that exact sequence on the composer and then looks at
    /// whether a turn started (flow items / running marker / queue row). It also
    /// measures, separately, what Return does with no composition at all: send or
    /// newline. Both are facts about the shipped page, and the second one is what
    /// the task asks to record rather than change.
    private func runIME() async {
        await sample(label: "ime-before")

        // A DRAFT HAS TO BE THERE FIRST.
        //
        // Measured the hard way: the first version of this sequence dispatched
        // `compositionend` + Return onto an EMPTY draft, and an empty draft makes
        // the page ignore Return for a reason that has nothing to do with IME —
        // so the run "proved" that composition-and-Return does not send, which is
        // the answer the task is hoping for and therefore the worst possible
        // wrong result to publish. The draft is now put in place and confirmed
        // present before anything is pressed, and the confirm is recorded.
        _ = await evaluate(Self.focusThroughTouchScript())
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.insertTextScript("nihao"))
        try? await Task.sleep(nanoseconds: 900_000_000)
        let seeded = await evaluate(Self.draftTextScript()) as? String ?? "nil"
        append(["event": "ime-draft-seeded", "draft": seeded])
        if seeded.contains("\"length\":0") || seeded == "nil" {
            append(["event": "ime-aborted",
                    "why": "no draft in the composer; a Return here would measure nothing"])
        }

        // (a) The composition path. WebKit delivers compositionend FIRST, then a
        // Return keydown with isComposing false and keyCode 229.
        let before = await flowCount()
        let composed = await evaluate(Self.compositionThenReturnScript()) as? String ?? "nil"
        append(["event": "composition-sequence", "result": composed])
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await sample(label: "ime-after-composition-return")
        let afterComposed = await flowCount()
        let draftAfterComposition = await evaluate(Self.draftTextScript()) as? String ?? "nil"
        append(["event": "ime-verdict",
                "flowBefore": before, "flowAfter": afterComposed,
                "sentAMessage": afterComposed > before,
                "draftAfter": draftAfterComposition])

        // (b) Return with no composition at all: send, or newline?
        _ = await evaluate(Self.clearDraftScript())
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = await evaluate(Self.insertTextScript("第一行"))
        try? await Task.sleep(nanoseconds: 900_000_000)
        append(["event": "plain-draft-seeded", "draft": (await evaluate(Self.draftTextScript())) ?? "nil"])
        let beforePlain = await flowCount()
        let plain = await evaluate(Self.plainReturnScript()) as? String ?? "nil"
        append(["event": "plain-return", "result": plain])
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let afterPlain = await flowCount()
        append(["event": "plain-return-verdict",
                "flowBefore": beforePlain, "flowAfter": afterPlain,
                "sentAMessage": afterPlain > beforePlain,
                "draftAfter": (await evaluate(Self.draftTextScript())) ?? "nil",
                "bodyMentionsPrompt": (await evaluate("(document.body.innerText||'').indexOf('第一行') >= 0")) ?? "nil"])
        await sample(label: "ime-after-plain-return")

        // (c) Shift+Return, the documented newline gesture, for comparison.
        _ = await evaluate(Self.clearDraftScript())
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = await evaluate(Self.insertTextScript("换行测试"))
        try? await Task.sleep(nanoseconds: 900_000_000)
        let shift = await evaluate(Self.shiftReturnScript()) as? String ?? "nil"
        append(["event": "shift-return", "result": shift])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        append(["event": "shift-return-verdict",
                "draftAfter": (await evaluate(Self.draftTextScript())) ?? "nil",
                "flowAfter": await flowCount()])
        await sample(label: "ime-after-shift-return")
    }

    /// Focus the composer the way a press on it does, including the touch.
    ///
    /// Step 11's guard (MobileWebTuning §3b) only lets focus move into the draft
    /// when the press landed on the draft, and it learns that from `touchstart`.
    /// A bare `focus()` from a script is refused by design, so a measurement that
    /// wants a focused composer has to include the touch.
    static func focusThroughTouchScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          try {
            box.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true }));
          } catch (error) { /* the guard also accepts a press on the card */ }
          box.focus();
          return 'focused:' + (document.activeElement === box);
        })();
        """
    }

    /// Session list: how many presses, and what a left-edge drag does.
    ///
    /// The presses are counted, not timed: each step is one `click()` on the one
    /// control that could plausibly be the next move, and the record says which
    /// control it was. A drag from the left edge is dispatched as a full pointer
    /// sequence, which is what a page-level gesture recogniser would see — but
    /// NOT what an iOS system edge gesture sees, so the record marks it
    /// `synthetic: true` and the report says a real touch is needed.
    private func runSidebar() async {
        await sample(label: "sidebar-closed")
        append(["event": "rail-measurement", "measure": await railMeasurement()])

        // 1. Open the drawer the way a finger would: the rail's own toggle.
        //    Recorded with the tap count, because "how many presses" is the
        //    question, and a step that silently does two things would answer a
        //    different question than the one asked.
        let opened = await evaluate(Self.pressSidebarToggleScript()) as? String ?? "nil"
        append(["event": "press-1", "taps": 1, "target": "sidebar toggle", "result": opened])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "sidebar-after-1-press")
        append(["event": "sidebar-state-after-1", "state": await sidebarState()])

        // 2. Press the first session row if it is now in the DOM.
        let pressed = await evaluate(Self.pressFirstSessionRowScript()) as? String ?? "nil"
        append(["event": "press-2", "taps": 2, "target": "first session row", "result": pressed])
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        await sample(label: "sidebar-after-2-press")
        append(["event": "sidebar-state-after-2", "state": await sidebarState()])

        // 3. Close it again FIRST, then drag from the left edge. The first
        //    version of this sequence dragged while the drawer was already open,
        //    so "the drag did nothing" and "the drag closed what was open" were
        //    the same observation — it recorded a close it had caused with the
        //    press before it. Closing first makes the drag's effect attributable.
        _ = await evaluate(Self.pressSidebarToggleScript())
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        append(["event": "sidebar-before-drag", "state": await sidebarState()])
        let drag = await evaluate(Self.leftEdgeDragScript()) as? String ?? "nil"
        append(["event": "left-edge-drag", "synthetic": true, "result": drag])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "sidebar-after-edge-drag")
        append(["event": "sidebar-state-after-drag", "state": await sidebarState()])
    }

    /// Dark mode: the two native bands against the page's own background.
    ///
    /// Three colours have to agree for the screen to look like one thing: what
    /// UIKit paints around the web view (the status bar band and the home
    /// indicator band), what the document paints, and what the page's frame
    /// paints. DSH has its own theme switch and can disagree with the iOS
    /// appearance, which is the case this records: `pageTheme` is read from the
    /// page, not assumed from the appearance.
    private func runDark() async {
        await sample(label: "dark-before")
        append(["event": "dark-colours", "colours": await colourFacts()])
        if Self.appearance == nil {
            // No forced appearance: flip the window's own style and measure BOTH
            // sides of it, on the page and in the native band. The native band is
            // read from the window's root view after the mirror has had time to
            // run, which is what `appFacts()` records.
            for wanted in ["dark", "light"] {
                applyAppearance(wanted)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await sample(label: "dark-flip-\(wanted)")
                append(["event": "dark-colours-\(wanted)", "colours": await colourFacts(),
                        "native": appFacts()])
            }
        }
        // The disagreement case the task names: the PAGE fixed to one theme while
        // iOS says the other. This is the only state in which the two can be told
        // apart, so it is measured deliberately rather than waited for.
        for (page, ios) in [("light", "dark"), ("dark", "light")] {
            applyAppearance(ios)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let forced = await evaluate(Self.forcePageThemeScript(page)) as? String ?? "nil"
            append(["event": "page-theme-forced", "page": page, "ios": ios, "result": forced])
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await sample(label: "dark-mismatch-\(page)-page-\(ios)-ios")
            append(["event": "dark-mismatch", "page": page, "ios": ios,
                    "colours": await colourFacts(), "native": appFacts()])
        }
        _ = await evaluate(Self.forcePageThemeScript("system"))
    }

    /// Put the page into a fixed theme by writing the attributes DSH itself
    /// writes, so a mismatch between page and iOS can be measured on purpose.
    ///
    /// This does NOT go through DSH's theme service (which has no reachable
    /// entry point from the outside); it writes the two attributes the service
    /// itself writes and the token stylesheet keys on. Good enough to answer "do
    /// the native bands follow the page", which is the question; the report says
    /// so explicitly.
    static func forcePageThemeScript(_ scheme: String) -> String {
        """
        (function () {
          const root = document.documentElement;
          const body = document.body;
          if (body === null) return 'no-body';
          if ('\(scheme)' === 'system') {
            root.removeAttribute('data-ds-theme-source');
            return 'released';
          }
          const dark = '\(scheme)' === 'dark';
          root.setAttribute('data-ds-theme-source', dark ? 'dark' : 'light');
          if (dark) body.setAttribute('data-ds-dark-theme', '');
          else body.removeAttribute('data-ds-dark-theme');
          return 'forced:' + '\(scheme)';
        })();
        """
    }

    /// Does a steered message actually reach the model, inside the running turn?
    ///
    /// WHAT THE FIRST ATTEMPT COULD NOT SHOW. The send-mode sweep pressed "steer"
    /// and then reported that the queued row disappeared — which proves the UI
    /// accepted it, not that the text arrived. The mock's request log is the only
    /// witness to the second half, and the run ended before the turn reached its
    /// next step boundary, so the log had nothing to show.
    ///
    /// So: a turn whose steps are SHORT (a bash `sleep 4` each, so a boundary
    /// arrives every few seconds), then a queued message carrying a unique marker,
    /// then the steer press, then a long tail. The host script
    /// (`scripts/step15-sendmode.py`) then looks for that marker in the mock's
    /// request log AFTER the recorded timestamp — which is what makes "the model
    /// saw it, and saw it inside the same turn" checkable.
    private func runSteerDelivery() async {
        let marker = UserDefaults.standard.string(forKey: "DSHPortEStep15Marker") ?? "STEP15MARK"
        await sample(label: "steer-start")
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await evaluate(Self.insertTextScript(Self.shortStepPrompt))
        try? await Task.sleep(nanoseconds: 500_000_000)
        append(["event": "steer-turn-sent", "result": await evaluate(Self.pressPrimaryScript()) ?? "nil"])
        // Wait until the turn is visibly running and has produced at least one
        // step, so the steer lands mid-turn rather than before it.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await sample(label: "steer-turn-running")
        let beforeFlow = await flowCount()

        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.insertTextScript("\(marker) 插话送达验证"))
        try? await Task.sleep(nanoseconds: 400_000_000)
        append(["event": "steer-queued-for-delivery",
                "marker": marker,
                "press": await evaluate(Self.pressPrimaryScript()) ?? "nil"])
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        append(["event": "steer-queue-state", "queue": await queueState()])

        let steerPress = await evaluate(Self.pressQueueSteerScript()) as? String ?? "nil"
        append(["event": "steer-delivery-press", "result": steerPress,
                "at": ISO8601DateFormatter().string(from: Date()),
                "flowBefore": beforeFlow])
        // Long enough for at least two step boundaries.
        for tick in 1...8 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            append(["event": "steer-tail-\(tick)",
                    "flow": await flowCount(),
                    "running": await evaluate("document.querySelector('[class*=\"_running\"]') !== null") ?? "nil",
                    "queue": await queueState()])
        }
        await sample(label: "steer-end")
    }

    /// Four bash steps of 4 s each: a step boundary every few seconds, which is
    /// what a steer needs in order to be consumed while the turn is still alive.
    private static let shortStepPrompt = """
    BASHTEST 插话送达验证：短步长回合。
    STEP sleep 4; echo steer-step-one
    STEP sleep 4; echo steer-step-two
    STEP sleep 4; echo steer-step-three
    STEP sleep 4; echo steer-step-four
    STEP sleep 4; echo steer-step-five
    STEP sleep 4; echo steer-step-six
    """

    /// One deliberately-disagreeing state: iOS in one appearance, the page fixed
    /// to the other.
    ///
    /// A separate action rather than a stage of `dark`, because a screenshot can
    /// only be taken at the end: a state that flips through four combinations and
    /// then shoots leaves one picture with four possible explanations. This one
    /// sets exactly one combination and stops, so the PNG that follows belongs to
    /// the numbers recorded beside it.
    ///
    /// `-DSHPortEStep15Appearance` is the iOS side; `-DSHPortEStep15PageTheme` is
    /// the page side.
    private func runMismatch() async {
        let page = UserDefaults.standard.string(forKey: "DSHPortEStep15PageTheme") ?? "light"
        await sample(label: "mismatch-before")
        let forced = await evaluate(Self.forcePageThemeScript(page)) as? String ?? "nil"
        append(["event": "mismatch-forced", "page": page,
                "ios": Self.appearance ?? "system", "result": forced])
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        await sample(label: "mismatch-state")
        append(["event": "mismatch-colours", "page": page, "ios": Self.appearance ?? "system",
                "colours": await colourFacts(), "native": appFacts()])
    }

    /// A long code block, and whether it widens the document.
    ///
    /// THE FIRST VERSION MEASURED NOTHING. It sampled `pre` elements on a
    /// transcript that had none — `preCount: 0` — and "the document is not wider
    /// than the viewport" is trivially true with nothing in it. So the reply is
    /// now asked for: the mock's CODEBLOCK script returns one fenced block with a
    /// single line wider than the phone, and the measurement runs after that
    /// reply has landed and says so.
    private func runCode() async {
        await sample(label: "code-before")
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await evaluate(Self.insertTextScript("CODEBLOCK 长代码块横向量测"))
        try? await Task.sleep(nanoseconds: 500_000_000)
        let sent = await evaluate(Self.pressPrimaryScript()) as? String ?? "nil"
        append(["event": "code-prompt-sent", "result": sent])
        _ = try? await waitForIdle(timeout: 60)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "code-with-reply")
        let stats = await evaluate(Self.codeStatsScript()) as? String ?? "nil"
        append(["event": "code-stats", "stats": stats])
    }

    /// Wait until no reply is still arriving.
    private func waitForIdle(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = (await evaluate("document.querySelector('[class*=\"_running\"]') !== null")) as? Bool
            if running == false { return true }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }

    /// Background for N seconds, then back.
    ///
    /// The app is put into the background from HERE, not from the host, because
    /// `simctl` has no "send to home" verb: pressing the home button is a UI
    /// action. What this can do without leaving the app is resign active and then
    /// become active again, which is exactly the pair of notifications a
    /// background/foreground cycle delivers, and it is recorded as such —
    /// `simulated: true` — so the report does not claim a real Home press.
    ///
    /// The alternative, an XCUITest `XCUIDevice.shared.press(.home)`, is what the
    /// device test does instead; the report says which half came from where.
    private func runResume() async {
        await sample(label: "resume-before")
        let mark = await evaluate(Self.resumeMarkScript()) as? String ?? "nil"
        append(["event": "resume-marked", "mark": mark])

        // Put a draft in the composer, so "the draft survived" is a claim about
        // something being there.
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.insertTextScript("切后台前的草稿"))
        try? await Task.sleep(nanoseconds: 800_000_000)
        append(["event": "resume-draft-typed", "draft": (await evaluate(Self.draftTextScript())) ?? "nil"])

        // Scroll the transcript a little, so the scroll position is a number that
        // can move rather than always 0.
        _ = await evaluate(Self.scrollTranscriptScript())
        try? await Task.sleep(nanoseconds: 600_000_000)
        let marked = await evaluate(Self.resumeMarkScript()) as? String ?? "nil"
        append(["event": "resume-marked-with-draft", "mark": marked])

        // Simulate the lifecycle transition.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.windows.forEach { window in
                    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: window)
                    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: window)
                }
            }
        append(["event": "lifecycle-background", "simulated": true])
        try? await Task.sleep(nanoseconds: UInt64(Self.hold * 1_000_000_000))
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.windows.forEach { window in
                    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: window)
                    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: window)
                }
            }
        append(["event": "lifecycle-foreground", "simulated": true])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "resume-after")
        append(["event": "resume-compare", "compare": await evaluate(Self.resumeCompareScript()) ?? "nil"])
    }

    /// The 56 pt rail, and the four destinations behind it.
    ///
    /// The injection does the work (see `MobileWebTuning`); this records what it
    /// achieved and, just as important, what it must NOT have changed: the
    /// transcript's width, the document's width, and — on iPad and in landscape —
    /// DSH's own 56 pt rail, which is measured by the same script and reported as
    /// `mediaMatches: false`.
    private func runRail() async {
        append(["event": "rail-before", "measure": await railMeasurement()])
        await sample(label: "rail-before")

        let edge = await evaluate(Self.railEdgeScript()) as? String ?? "nil"
        append(["event": "rail-edge", "result": edge])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        append(["event": "rail-open", "state": await railMeasurement()])
        await sample(label: "rail-open")

        let reach = await evaluate(Self.railReachScript()) as? String ?? "nil"
        append(["event": "rail-reach", "reach": reach])

        // Close it again and confirm the transcript got its width back. Both
        // directions are separate facts: "it opens" without "it closes" would
        // leave the transcript 280 pt narrower for the rest of the session.
        _ = await evaluate(Self.railScrimScript())
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        append(["event": "rail-closed", "state": await railMeasurement()])
        await sample(label: "rail-closed")
    }

    static func railEdgeScript() -> String {
        """
        (function () {
          const edge = document.getElementById('dsh-mobile-rail-edge');
          if (edge === null) return 'no-edge';
          const rect = edge.getBoundingClientRect();
          const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          edge.click();
          return JSON.stringify({
            label: edge.getAttribute('aria-label'),
            width: Math.round(rect.width), top: Math.round(rect.top), height: Math.round(rect.height),
            hitIsSelfOrChild: hit !== null && (hit === edge || edge.contains(hit)),
          });
        })();
        """
    }

    static func railScrimScript() -> String {
        """
        (function () {
          const scrim = document.getElementById('dsh-mobile-rail-scrim');
          if (scrim === null) return 'no-scrim';
          scrim.click();
          return 'scrim-pressed';
        })();
        """
    }

    /// The three send modes while a turn is running.
    ///
    /// DSH resolves the primary button's mode from the `busyEnter` preference
    /// (`queue` by default) and its own busy state; `steer` is reachable either
    /// through that preference or through the queued row's own steer action. The
    /// question here is not which one is correct, it is whether each is
    /// *reachable and effective on a phone* — no hover, no long press, no
    /// right-click.
    private func runSendModes() async {
        await sample(label: "send-idle")

        // Start a turn long enough to act inside. The mock's BASHTEST script
        // turns STEP lines into bash tool calls with a real sleep each, so the
        // turn stays busy for tens of seconds.
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await evaluate(Self.insertTextScript(Self.longTurnPrompt))
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await evaluate(Self.pressPrimaryScript())
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await sample(label: "send-running")
        append(["event": "running-controls", "controls": await sendControls()])

        // (1) Queue: type a second prompt and press the primary button.
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.insertTextScript("排队测试：这一条应该等这一轮做完再发"))
        try? await Task.sleep(nanoseconds: 400_000_000)
        append(["event": "queue-controls-before", "controls": await sendControls()])
        let queued = await evaluate(Self.pressPrimaryScript()) as? String ?? "nil"
        append(["event": "queue-press", "result": queued])
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await sample(label: "send-queued")
        append(["event": "queue-state", "queue": await queueState()])

        // (2) Interrupt: the separate stop button that appears beside it.
        let stopped = await evaluate(Self.pressStopScript()) as? String ?? "nil"
        append(["event": "stop-press", "result": stopped])
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await sample(label: "send-stopped")
        append(["event": "stop-state", "controls": await sendControls()])

        // (3) Steer: send a long turn again, queue one message, then steer that
        // queued row into the running turn through its own button.
        _ = await evaluate(Self.clearDraftScript())
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.insertTextScript(Self.longTurnPrompt))
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await evaluate(Self.pressPrimaryScript())
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        _ = await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await evaluate(Self.insertTextScript("插话测试：这一条要插进正在跑的回合"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await evaluate(Self.pressPrimaryScript())
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await sample(label: "steer-queued")
        append(["event": "steer-before", "queue": await queueState()])
        let steerPress = await evaluate(Self.pressQueueSteerScript()) as? String ?? "nil"
        append(["event": "steer-press", "result": steerPress])
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await sample(label: "steer-after")
        append(["event": "steer-after-state", "queue": await queueState(),
                "controls": await sendControls()])
    }

    /// Sample the launch screen while it is still on screen.
    ///
    /// THE METHOD ABOVE WAS TOO LATE. `runBoot` runs after the composer exists,
    /// which is by definition after the boot screen is gone — it measured
    /// `onScreenCount: 0`, i.e. an empty screen, and "no version string is
    /// visible" would then be true for the trivial reason that nothing was
    /// visible. That is the same class of mistake as the empty-draft IME run.
    ///
    /// So the boot state is sampled from the START of the app, on a fixed
    /// schedule, whether or not the page has loaded: 0.15 s, 0.6 s, 1.5 s, 3 s,
    /// 5 s. Each sample records the labels the window is actually showing, which
    /// is what the question ("does a normal launch show node/v8") is about.
    func scheduleBootSamples() {
        guard Self.isEnabled, Self.action == "boot", !bootScheduled else { return }
        bootScheduled = true
        append(["event": "boot-schedule", "launchInstant": ISO8601DateFormatter().string(from: Self.launchInstant)])
        for delay in [0.15, 0.6, 1.5, 3.0, 5.0, 7.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.append(["event": "boot-sample",
                             "afterSeconds": delay,
                             "secondsSinceLaunch": round(Date().timeIntervalSince(Self.launchInstant) * 100) / 100,
                             "screen": self.bootScreenFacts(),
                             "hierarchy": Self.visibleTextFacts()])
            }
        }
    }

    /// What the cold-start screen shows, and how long each phase takes.
    ///
    /// The task asks for two things about launch: no developer information on a
    /// normal start, and no white flash between the launch screen and the page.
    /// The first is a fact about the boot screen's own text, so it is read from
    /// the view hierarchy (the labels the user would see) rather than from the
    /// source that renders them. The second is not a property of any one frame —
    /// it is the brightness across a recording — so it is measured on the host
    /// from a video, and this only records the timeline the host can line up
    /// against.
    private func runBoot() async {
        append(["event": "boot-timeline",
                "launchedAt": ISO8601DateFormatter().string(from: Date()),
                "secondsSinceLaunch": Date().timeIntervalSince(Self.launchInstant)])
        append(["event": "boot-text", "text": Self.visibleTextFacts()])
        await sample(label: "boot-page-up")
        append(["event": "boot-timeline-page-up",
                "secondsSinceLaunch": round(Date().timeIntervalSince(Self.launchInstant) * 100) / 100])
    }

    /// What the boot screen itself says, pushed here by the view model.
    ///
    /// WALKING THE VIEW HIERARCHY DOES NOT WORK for this question, and that was
    /// measured rather than assumed: with the boot screen plainly on screen, both
    /// a `UILabel` walk and an accessibility walk returned ZERO texts — SwiftUI
    /// draws `Text` into hosting views and does not publish them as either while
    /// the launch is still in progress. Two attempts, both empty.
    ///
    /// So the boot screen reports its own content instead. That is not weaker: the
    /// question is precisely "does the boot screen put a node version in front of
    /// the user", and the boot screen is the only thing that decides what it puts
    /// there. `runtimeFacts` is the only place a version string can come from, so
    /// its presence-or-absence at each sample is the answer.
    struct BootScreenSnapshot {
        var headline: String = ""
        var detail: String = ""
        var runtimeFacts: String?
    }

    private var bootSnapshot = BootScreenSnapshot() {
        didSet { /* read by the scheduled samples */ }
    }

    func noteBootScreen(headline: String, detail: String, runtimeFacts: String?) {
        bootSnapshot = BootScreenSnapshot(headline: headline, detail: detail, runtimeFacts: runtimeFacts)
    }

    /// The facts of one boot sample, from the boot screen's own content.
    private func bootScreenFacts() -> [String: Any] {
        let facts = bootSnapshot.runtimeFacts ?? ""
        let joined = [bootSnapshot.headline, bootSnapshot.detail, facts].joined(separator: " | ")
        return [
            "headline": bootSnapshot.headline,
            "detail": bootSnapshot.detail,
            "runtimeFactsPresent": bootSnapshot.runtimeFacts != nil,
            "runtimeFacts": String(facts.prefix(200)),
            "visibleText": String(joined.prefix(400)),
            "mentionsNodeVersion": joined.lowercased().contains("node "),
            "mentionsV8": joined.lowercased().contains("v8"),
            "mentionsModules": joined.lowercased().contains("modules"),
            "mentionsJitless": joined.lowercased().contains("jitless"),
            "webViewAlreadyUp": webView != nil && (webView?.url != nil),
        ]
    }

    /// Every piece of text on screen right now, from the view hierarchy.
    ///
    /// This is the honest answer to "does a normal launch show node/v8 versions":
    /// a `Text` that is in the SwiftUI tree but off screen is not what the user
    /// sees, and a string search in the source cannot tell the difference. Labels
    /// are collected with their frames, so a version string sitting behind a
    /// `.hidden` or zero-height container is distinguishable from a visible one.
    static func visibleTextFacts() -> [String: Any] {
        // Written as two statements because a guard condition cannot carry a
        // trailing closure: `guard let x = ….first(where: { … }) else` is parsed
        // as the guard's own body and fails with "expected 'else'".
        let keyWindow: UIWindow? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        guard let window = keyWindow else { return ["window": "absent"] }
        var texts: [[String: Any]] = []
        // TWO SOURCES, because SwiftUI does not use `UILabel` for `Text`: it draws
        // into its own host views and exposes the string through accessibility.
        // A `UILabel`-only walk reported `onScreenCount: 0` for a screen that
        // plainly had text on it — measured — so the accessibility tree is read
        // as well, and both are recorded with their source so the report can say
        // which one answered.
        func walk(_ view: UIView, depth: Int) {
            if depth > 40 { return }
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                let rect = label.convert(label.bounds, to: window)
                texts.append([
                    "source": "uilabel",
                    "text": String(text.prefix(120)),
                    "hidden": label.isHidden, "alpha": Double(label.alpha),
                    "y": Double(rect.origin.y), "height": Double(rect.height),
                    "onScreen": !label.isHidden && label.alpha > 0.01 && rect.height > 0,
                ])
            }
            // Accessibility: what a screen reader would announce, which is
            // the closest thing to "the text the user can read".
            if view.isAccessibilityElement, let value = view.accessibilityLabel, !value.isEmpty {
                let rect = view.convert(view.bounds, to: window)
                texts.append([
                    "source": "accessibility",
                    "text": String(value.prefix(120)),
                    "hidden": view.isHidden, "alpha": Double(view.alpha),
                    "y": Double(rect.origin.y), "height": Double(rect.height),
                    "onScreen": !view.isHidden && view.alpha > 0.01
                        && rect.height > 0 && rect.width > 0,
                ])
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window, depth: 0)
        // And the containers' own accessibility labels, which is where SwiftUI
        // often puts a stack's combined text.
        func walkLabels(_ view: UIView, depth: Int) {
            if depth > 40 { return }
            if !view.isAccessibilityElement, let label = view.accessibilityLabel, !label.isEmpty {
                let rect = view.convert(view.bounds, to: window)
                texts.append([
                    "source": "container-label",
                    "text": String(label.prefix(200)),
                    "hidden": view.isHidden, "alpha": Double(view.alpha),
                    "y": Double(rect.origin.y), "height": Double(rect.height),
                    "onScreen": !view.isHidden && view.alpha > 0.01 && rect.height > 0,
                ])
            }
            for sub in view.subviews { walkLabels(sub, depth: depth + 1) }
        }
        walkLabels(window, depth: 0)
        let onScreen = texts.filter { ($0["onScreen"] as? Bool) == true }
        let joined = onScreen.compactMap { $0["text"] as? String }.joined(separator: " | ")
        return [
            "all": texts,
            "onScreenCount": onScreen.count,
            "onScreenText": String(joined.prefix(600)),
            // The specific strings a developer-facing launch screen would show.
            "mentionsNodeVersion": joined.lowercased().contains("node "),
            "mentionsV8": joined.lowercased().contains("v8"),
            "mentionsModules": joined.lowercased().contains("modules"),
            "mentionsJitless": joined.lowercased().contains("jitless"),
        ]
    }

    /// Two quick taps on two different controls.
    ///
    /// Step 11 guarded against double-tap zoom with a script that blocked any
    /// second `touchend` within 320 ms, wherever it landed. Two different buttons
    /// pressed in quick succession are exactly the case that guard cannot tell
    /// apart from a double tap, so this presses two distinct controls 120 ms
    /// apart and records whether both of them acted.
    private func runTap() async {
        append(["event": "tap-before", "controls": await sendControls()])
        let result = await evaluate(Self.twoTapsScript()) as? String ?? "nil"
        append(["event": "two-taps", "result": result])
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        append(["event": "tap-after", "controls": await sendControls()])
        await sample(label: "tap-after")
    }

    /// Evaluate a host-supplied script file. See the header for why this exists.
    ///
    /// TWO PHASES, because `evaluateJavaScript` does not await a promise and
    /// because the questions here are about what happens *after* an interaction:
    /// phase 1 performs it and leaves facts on `window`, the probe waits, phase 2
    /// reads what settled. A single-phase script can only report the instant it
    /// ran, which is exactly the window in which nothing has happened yet.
    private func runEvalFile() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = ["DSHPortE-step15-script.js",
                     "DSHPortE-step15-script2.js",
                     "DSHPortE-step15-script3.js",
                     "DSHPortE-step15-script4.js",
                     "DSHPortE-step15-script5.js"]
        var ran = false
        for (index, name) in names.enumerated() {
            let path = documents.appendingPathComponent(name)
            guard let script = try? String(contentsOf: path, encoding: .utf8) else { continue }
            if index > 0 { try? await Task.sleep(nanoseconds: UInt64(Self.hold * 1_000_000_000)) }
            append(Self.evalRecord("eval-\(index + 1)", script.count, await evaluate(script)))
            ran = true
        }
        if !ran { append(["event": "eval-missing", "path": names[0]]) }
    }

    private static func evalRecord(_ event: String, _ bytes: Int, _ value: Any?) -> [String: Any] {
        var record: [String: Any] = ["event": event, "bytes": bytes]
        if let text = value as? String, let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            record["json"] = parsed
        } else {
            record["value"] = value ?? "nil"
        }
        return record
    }

    // MARK: - Facts

    private func flowCount() async -> Int {
        let raw = await evaluate("document.querySelectorAll('[data-chat-flow-kind]').length")
        return (raw as? NSNumber)?.intValue ?? -1
    }

    private func sidebarState() async -> Any {
        await evaluate(Self.sidebarStateScript()) ?? "nil"
    }

    private func railMeasurement() async -> Any {
        await evaluate(Self.railMeasureScript()) ?? "nil"
    }

    private func colourFacts() async -> Any {
        await evaluate(Self.colourScript()) ?? "nil"
    }

    private func sendControls() async -> Any {
        await evaluate(Self.sendControlsScript()) ?? "nil"
    }

    private func queueState() async -> Any {
        await evaluate(Self.queueStateScript()) ?? "nil"
    }

    /// The anti-regression verdict, from both sides of the boundary.
    private func safeAreaVerdict() -> [String: Any] {
        var out: [String: Any] = [:]
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window, let webView else {
            out["error"] = "no window or web view"
            return out
        }
        let safeTop = Double(window.safeAreaInsets.top)
        let rect = webView.convert(webView.bounds, to: window)
        out["safeAreaTop"] = safeTop
        out["webViewY"] = Double(rect.origin.y)
        out["webViewHeight"] = Double(rect.height)
        out["windowHeight"] = Double(window.bounds.height)
        // The native half: the web view must start at or below the safe area.
        out["nativePass"] = Double(rect.origin.y) >= safeTop - 0.5
        return out
    }

    // MARK: - Sampling

    private func sample(label: String) async {
        let dom = await evaluate(InteractionProbe.measureScript())
        var record: [String: Any] = [
            "label": label,
            "at": ISO8601DateFormatter().string(from: Date()),
            "app": appFacts(),
        ]
        if let raw = dom as? String, let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            record["dom"] = parsed
        } else {
            record["dom"] = dom ?? "nil"
        }
        append(record)
    }

    private func appFacts() -> [String: Any] {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var facts: [String: Any] = [
            "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "systemVersion": UIDevice.current.systemVersion,
        ]
        if let window {
            facts["windowHeight"] = Double(window.bounds.height)
            facts["windowWidth"] = Double(window.bounds.width)
            facts["safeAreaTop"] = Double(window.safeAreaInsets.top)
            facts["safeAreaBottom"] = Double(window.safeAreaInsets.bottom)
            facts["interfaceStyle"] = window.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            // What UIKit paints around the page, straight from the view that
            // does it: the background of the root view behind the web view.
            if let root = window.rootViewController?.view {
                facts["rootBackground"] = Self.hexColour(root.backgroundColor)
            }
        }
        if let webView {
            let rect = webView.convert(webView.bounds, to: window)
            facts["webViewFrame"] = [
                "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                "width": Double(rect.width), "height": Double(rect.height),
            ]
            facts["webViewBackground"] = Self.hexColour(webView.backgroundColor)
            facts["underPageBackground"] = Self.hexColour(webView.underPageBackgroundColor)
        }
        return facts
    }

    /// A colour as `#rrggbb`, resolved against the current traits.
    private static func hexColour(_ colour: UIColor?) -> String {
        guard let colour else { return "nil" }
        let resolved = colour.resolvedColor(with: UITraitCollection.current)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "unresolvable" }
        return String(format: "#%02x%02x%02x/%.2f", Int(red * 255), Int(green * 255), Int(blue * 255), alpha)
    }

    // MARK: - Scripts

    private static let longTurnPrompt = """
    BASHTEST 第 15 单的发送方式测试：这一轮要跑得足够久。
    STEP sleep 12; echo step-one
    STEP sleep 12; echo step-two
    STEP sleep 12; echo step-three
    STEP sleep 12; echo step-four
    """

    static func focusComposerScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]')
            || document.querySelector('[contenteditable="true"]');
          if (box === null) return 'no-composer';
          const rect = box.getBoundingClientRect();
          const init = {
            bubbles: true, cancelable: true, composed: true, button: 0,
            buttons: 1, pointerId: 1, pointerType: 'touch', isPrimary: true,
            clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2,
          };
          box.dispatchEvent(new PointerEvent('pointerdown', init));
          box.dispatchEvent(new MouseEvent('mousedown', init));
          box.dispatchEvent(new PointerEvent('pointerup', init));
          box.dispatchEvent(new MouseEvent('mouseup', init));
          box.dispatchEvent(new MouseEvent('click', init));
          box.focus();
          return 'focused:' + (document.activeElement === box);
        })();
        """
    }

    static func insertTextScript(_ text: String) -> String {
        """
        (function () {
          const text = \(jsString(text));
          const box = document.querySelector('[data-composer-input]')
            || document.querySelector('[contenteditable="true"]');
          if (box === null) return 'no-composer';
          // The touch is part of typing: step 11's guard only lets focus into the
          // draft when the press landed on it.
          try {
            box.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true }));
          } catch (error) { /* the card press is the other accepted shape */ }
          box.focus();
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(box);
          range.collapse(false);
          selection.removeAllRanges();
          selection.addRange(range);
          try {
            const clipboard = new DataTransfer();
            clipboard.setData('text/plain', text);
            const paste = new ClipboardEvent('paste', {
              bubbles: true, cancelable: true, clipboardData: clipboard,
            });
            box.dispatchEvent(paste);
            if (paste.defaultPrevented) return 'paste|rendered=' + (box.innerText || '').length;
          } catch (error) { /* not constructible here */ }
          document.execCommand('insertText', false, text);
          return 'execCommand|rendered=' + (box.innerText || '').length;
        })();
        """
    }

    /// Quote a Swift string as a JavaScript literal.
    private static func jsString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    static func clearDraftScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          box.focus();
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(box);
          selection.removeAllRanges();
          selection.addRange(range);
          try {
            const clipboard = new DataTransfer();
            clipboard.setData('text/plain', '');
            box.dispatchEvent(new ClipboardEvent('paste', {
              bubbles: true, cancelable: true, clipboardData: clipboard,
            }));
          } catch (error) { /* ignore */ }
          // Belt and braces: the editor may refuse an empty paste.
          if ((box.innerText || '').trim() !== '') {
            document.execCommand('selectAll', false, null);
            document.execCommand('delete', false, null);
          }
          return 'cleared|left=' + (box.innerText || '').length;
        })();
        """
    }

    static func draftTextScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          return JSON.stringify({
            text: (box.innerText || '').slice(0, 200),
            length: (box.innerText || '').length,
            newlines: ((box.innerText || '').match(/\\n/g) || []).length,
            childBlocks: box.children.length,
          });
        })();
        """
    }

    /// Composition commit, then Return — the order WebKit is reported to use.
    ///
    /// The three events carry what WebKit actually delivers: `compositionend`
    /// with the committed text, then `keydown` with `isComposing` false and
    /// `keyCode` 229, then `keyup`. If the page sends on that keydown, a person
    /// typing 拼音 and pressing Return to commit gets a sent message.
    static func compositionThenReturnScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          const before = document.querySelectorAll('[data-chat-flow-kind]').length;
          const fire = (type, init) => {
            const event = type.startsWith('composition')
              ? new CompositionEvent(type, init)
              : new KeyboardEvent(type, init);
            box.dispatchEvent(event);
            return event.defaultPrevented;
          };
          const composing = box.hasAttribute('data-composer-composing');
          const startPrevented = fire('compositionstart', { bubbles: true, cancelable: true, data: '' });
          fire('compositionupdate', { bubbles: true, cancelable: true, data: '你好' });
          // Commit: compositionend first, exactly as WebKit orders it.
          fire('compositionend', { bubbles: true, cancelable: true, data: '你好' });
          const keyInit = {
            bubbles: true, cancelable: true, key: 'Enter', code: 'Enter',
            keyCode: 229, which: 229, isComposing: false, composed: true,
          };
          const downPrevented = fire('keydown', keyInit);
          fire('keyup', { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 229, which: 229 });
          return JSON.stringify({
            startPrevented: startPrevented,
            keydownPrevented: downPrevented,
            flowBefore: before,
            flowAfter: document.querySelectorAll('[data-chat-flow-kind]').length,
            composingAttributeBefore: composing,
            composingAttributeAfter: box.hasAttribute('data-composer-composing'),
            draft: (box.innerText || '').slice(0, 120),
          });
        })();
        """
    }

    /// Return with nothing composing.
    static func plainReturnScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          box.focus();
          const before = document.querySelectorAll('[data-chat-flow-kind]').length;
          const init = {
            bubbles: true, cancelable: true, key: 'Enter', code: 'Enter',
            keyCode: 13, which: 13, isComposing: false, composed: true,
          };
          const down = new KeyboardEvent('keydown', init);
          box.dispatchEvent(down);
          box.dispatchEvent(new KeyboardEvent('keyup', init));
          return JSON.stringify({
            keydownPrevented: down.defaultPrevented,
            flowBefore: before,
            flowAfter: document.querySelectorAll('[data-chat-flow-kind]').length,
            draft: (box.innerText || '').slice(0, 120),
          });
        })();
        """
    }

    /// Shift+Return, the documented newline gesture.
    static func shiftReturnScript() -> String {
        """
        (function () {
          const box = document.querySelector('[data-composer-input]');
          if (box === null) return 'no-composer';
          box.focus();
          const before = document.querySelectorAll('[data-chat-flow-kind]').length;
          const init = {
            bubbles: true, cancelable: true, key: 'Enter', code: 'Enter',
            keyCode: 13, which: 13, shiftKey: true, isComposing: false, composed: true,
          };
          const down = new KeyboardEvent('keydown', init);
          box.dispatchEvent(down);
          box.dispatchEvent(new KeyboardEvent('keyup', init));
          return JSON.stringify({
            keydownPrevented: down.defaultPrevented,
            flowBefore: before,
            flowAfter: document.querySelectorAll('[data-chat-flow-kind]').length,
            draft: (box.innerText || '').slice(0, 120),
          });
        })();
        """
    }

    static func pageDumpScript() -> String {
        """
        (function () {
          return JSON.stringify({
            urlHasToken: location.href.indexOf('token=') >= 0,
            htmlLength: document.documentElement === null ? -1 : document.documentElement.outerHTML.length,
            title: document.title,
            bodyLength: document.body === null ? -1 : (document.body.innerText || '').length,
            composerCount: document.querySelectorAll('[data-composer-input]').length,
            readyState: document.readyState,
          });
        })();
        """
    }

    /// Everything the sidebar and rail questions need, in page coordinates.
    static func sidebarStateScript() -> String {
        """
        (function () {
          const frame = document.querySelector('[data-sidebar-collapsed], [class*="_frame"]');
          const col = document.querySelector('[class*="_sidebarCol"]');
          const rail = document.querySelector('[class*="_collapsed"]');
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0);
          const buttons = Array.from(document.querySelectorAll('button, [role="button"]'))
            .map((el) => ({
              label: (el.getAttribute('aria-label') || '').trim(),
              text: (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40),
              visible: el.getBoundingClientRect().width > 0,
            }))
            .filter((entry) => entry.visible && (entry.label !== '' || entry.text !== ''));
          return JSON.stringify({
            collapsedAttribute: frame === null ? null : frame.hasAttribute('data-sidebar-collapsed'),
            grid: frame === null ? null : getComputedStyle(frame).gridTemplateColumns,
            sidebarColWidth: col === null ? null : Math.round(col.getBoundingClientRect().width),
            railPresent: rail !== null,
            sessionRowCount: rows.length,
            sessionTitles: rows.slice(0, 8).map((el) => (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40)),
            visibleButtons: buttons.slice(0, 24),
            innerWidth: window.innerWidth,
          });
        })();
        """
    }

    /// The rail's own geometry, in pt, plus what the injection did to it.
    ///
    /// `mediaMatches` is the load-bearing field: the injected rules are scoped to
    /// `max-width: 520px` and `orientation: portrait`, so on an iPad or in
    /// landscape this must be `false` AND the sidebar column must still be the
    /// 56 pt rail DSH lays out itself. A `true` there would mean the phone-only
    /// rule leaked onto a device the task says must not change.
    static func railMeasureScript() -> String {
        """
        (function () {
          const col = document.querySelector('[class*="_frame"] > [class*="_sidebarCol"]');
          const center = document.querySelector('[class*="_centerCol"]');
          const frame = document.querySelector('[class*="_frame"]');
          const edge = document.getElementById('dsh-mobile-rail-edge');
          const scrim = document.getElementById('dsh-mobile-rail-scrim');
          const rectOf = (el) => el === null ? null : {
            x: Math.round(el.getBoundingClientRect().left),
            width: Math.round(el.getBoundingClientRect().width),
            height: Math.round(el.getBoundingClientRect().height),
          };
          const scroller = document.querySelector('[data-conversation-scroll]');
          return JSON.stringify({
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            mediaMatches: window.matchMedia('(max-width: 520px) and (orientation: portrait)').matches,
            railAttribute: document.documentElement.hasAttribute('data-dsh-rail'),
            drawerAttribute: document.documentElement.hasAttribute('data-dsh-rail-open'),
            frame: rectOf(frame),
            grid: frame === null ? null : getComputedStyle(frame).gridTemplateColumns,
            sidebarCol: rectOf(col),
            centerCol: rectOf(center),
            transcript: rectOf(scroller),
            collapsed: frame === null ? null : frame.hasAttribute('data-sidebar-collapsed'),
            edge: edge === null ? null : {
              width: Math.round(edge.getBoundingClientRect().width),
              top: Math.round(edge.getBoundingClientRect().top),
              label: edge.getAttribute('aria-label'),
            },
            scrimPresent: scrim !== null,
            sessionRows: Array.from(document.querySelectorAll('[data-row-key]'))
              .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0).length,
            documentScrollWidth: document.documentElement.scrollWidth,
            bodyScrollWidth: document.body.scrollWidth,
          });
        })();
        """
    }

    /// Press whatever control opens or closes the sidebar.
    static func pressSidebarToggleScript() -> String {
        """
        (function () {
          const wanted = ['打开侧边栏', '收起侧边栏', 'Open sidebar', 'Collapse sidebar'];
          const buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
          for (const button of buttons) {
            const label = (button.getAttribute('aria-label') || '').trim();
            if (!wanted.some((w) => label.indexOf(w) >= 0)) continue;
            const rect = button.getBoundingClientRect();
            if (rect.width === 0) continue;
            button.click();
            return 'pressed:' + label + '@' + Math.round(rect.left) + ',' + Math.round(rect.top);
          }
          return 'no-toggle';
        })();
        """
    }

    static func pressFirstSessionRowScript() -> String {
        """
        (function () {
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0);
          if (rows.length === 0) return 'no-session-row';
          const row = rows[0];
          const rect = row.getBoundingClientRect();
          row.click();
          return 'pressed:' + (row.getAttribute('data-row-key') || '') + '@' + Math.round(rect.left) + ',' + Math.round(rect.top);
        })();
        """
    }

    /// A drag that starts on the left edge and moves right, dispatched into the
    /// page. Synthetic: an iOS system edge gesture never reaches the DOM.
    static func leftEdgeDragScript() -> String {
        """
        (function () {
          const frame = document.querySelector('[class*="_frame"]') || document.body;
          const start = { x: 2, y: Math.round(window.innerHeight / 2) };
          const send = (type, x, y) => {
            const init = {
              bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: type === 'pointerup' ? 0 : 1, pointerId: 11,
              pointerType: 'touch', isPrimary: true, clientX: x, clientY: y,
            };
            frame.dispatchEvent(new PointerEvent(type, init));
            if (type !== 'pointermove') {
              frame.dispatchEvent(new MouseEvent('mouse' + type.slice(7), init));
            }
          };
          send('pointerdown', start.x, start.y);
          for (let step = 1; step <= 8; step += 1) {
            send('pointermove', start.x + step * 40, start.y);
          }
          send('pointerup', start.x + 320, start.y);
          const frame2 = document.querySelector('[class*="_frame"]');
          return JSON.stringify({
            synthetic: true,
            collapsedAfter: frame2 === null ? null : frame2.hasAttribute('data-sidebar-collapsed'),
            rowCount: Array.from(document.querySelectorAll('[data-row-key]'))
              .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0).length,
          });
        })();
        """
    }

    /// The four destinations behind the rail, and whether each is two presses or
    /// fewer away from the transcript.
    /// The four destinations the task says must stay reachable inside two
    /// presses: new conversation, history, search, and the account/"…" menu.
    ///
    /// Each one is reported with `hittable`, not just `visible`: an element can
    /// have a width and still be underneath the scrim, which is exactly the
    /// failure a drawer introduces. `elementFromPoint` on its centre is the
    /// difference between "drawn" and "pressable".
    static func railReachScript() -> String {
        """
        (function () {
          const wanted = ['新建会话', 'New session', '搜索会话', 'Search sessions',
                          '账号菜单', 'Account menu', '自动化任务', '收起侧边栏'];
          const found = {};
          for (const el of document.querySelectorAll('button, [role="button"], a')) {
            const label = (el.getAttribute('aria-label') || '').trim();
            if (!wanted.includes(label)) continue;
            const rect = el.getBoundingClientRect();
            const hit = rect.width === 0 ? null
              : document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            found[label] = {
              x: Math.round(rect.left), y: Math.round(rect.top),
              width: Math.round(rect.width), height: Math.round(rect.height),
              onScreen: rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight,
              hittable: hit !== null && (hit === el || el.contains(hit)),
            };
          }
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0);
          let rowHit = null;
          if (rows.length > 0) {
            const rect = rows[0].getBoundingClientRect();
            const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            rowHit = { x: Math.round(rect.left), y: Math.round(rect.top),
                       width: Math.round(rect.width),
                       hittable: hit !== null && (rows[0] === hit || rows[0].contains(hit)) };
          }
          return JSON.stringify({
            innerWidth: window.innerWidth,
            found: found,
            sessionRowCount: rows.length,
            firstRowHit: rowHit,
            titles: rows.slice(0, 5).map((el) => (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 30)),
          });
        })();
        """
    }

    /// The three colours that have to agree, plus the page's own theme marker.
    static func colourScript() -> String {
        """
        (function () {
          const bodyStyle = getComputedStyle(document.body);
          const htmlStyle = getComputedStyle(document.documentElement);
          const frame = document.querySelector('[class*="_frame"]');
          return JSON.stringify({
            darkAttribute: document.body.hasAttribute('data-ds-dark-theme'),
            bodyBackground: bodyStyle.backgroundColor,
            htmlBackground: htmlStyle.backgroundColor,
            frameBackground: frame === null ? null : getComputedStyle(frame).backgroundColor,
            themeSource: document.documentElement.getAttribute('data-ds-theme-source'),
            metaThemeColor: (function () {
              const meta = document.querySelector('meta[name="theme-color"]');
              return meta === null ? null : meta.getAttribute('content');
            })(),
            prefersDark: window.matchMedia('(prefers-color-scheme: dark)').matches,
            bgBaseToken: bodyStyle.getPropertyValue('--dsw-alias-bg-base').trim(),
            innerWidth: window.innerWidth,
          });
        })();
        """
    }

    /// Code blocks: does a long line scroll inside its own box or widen the page.
    ///
    /// Both sides of the task's sentence are measured: the DOCUMENT must not be
    /// wider than the viewport (`documentWidened`), and the code block itself must
    /// be the thing that scrolls (`scrollWidth > clientWidth` on the element that
    /// actually holds the overflow). `whiteSpace` and `longestLine` are recorded
    /// because "no overflow" has two very different causes — the block scrolls, or
    /// the block WRAPPED the line, which on a phone is also acceptable but is a
    /// different answer and must not be reported as the first.
    static func codeStatsScript() -> String {
        """
        (function () {
          const pres = Array.from(document.querySelectorAll('pre'));
          const scrollersOf = (el) => Array.from(el.querySelectorAll('*'))
            .filter((child) => child.scrollWidth > child.clientWidth + 1);
          return JSON.stringify({
            preCount: pres.length,
            pres: pres.slice(0, 4).map((pre) => ({
              width: Math.round(pre.getBoundingClientRect().width),
              scrollWidth: pre.scrollWidth,
              clientWidth: pre.clientWidth,
              scrollHeight: pre.scrollHeight,
              clientHeight: pre.clientHeight,
              overflowsInside: pre.scrollWidth > pre.clientWidth + 1,
              overflowX: getComputedStyle(pre).overflowX,
              whiteSpace: getComputedStyle(pre).whiteSpace,
              textLength: (pre.innerText || '').length,
              longestLine: (pre.innerText || '').split('\\n').reduce((max, line) => Math.max(max, line.length), 0),
              overflowingChildren: scrollersOf(pre).length,
            })),
            documentScrollWidth: document.documentElement.scrollWidth,
            documentClientWidth: document.documentElement.clientWidth,
            bodyScrollWidth: document.body.scrollWidth,
            innerWidth: window.innerWidth,
            documentWidened: document.documentElement.scrollWidth > window.innerWidth + 1,
          });
        })();
        """
    }

    /// Record a fingerprint of the visible state, for the resume comparison.
    static func resumeMarkScript() -> String {
        """
        (function () {
          const scroller = document.querySelector('[data-conversation-scroll]');
          const box = document.querySelector('[data-composer-input]');
          const mark = {
            flowCount: document.querySelectorAll('[data-chat-flow-kind]').length,
            scrollTop: scroller === null ? null : Math.round(scroller.scrollTop),
            scrollHeight: scroller === null ? null : Math.round(scroller.scrollHeight),
            draft: box === null ? '' : (box.innerText || ''),
            scrollY: window.scrollY,
            url: location.href.length,
          };
          window.__step15ResumeMark = mark;
          return JSON.stringify(mark);
        })();
        """
    }

    static func scrollTranscriptScript() -> String {
        """
        (function () {
          const scroller = document.querySelector('[data-conversation-scroll]');
          if (scroller === null) return 'no-scroller';
          const target = Math.max(0, Math.round(scroller.scrollHeight * 0.4));
          scroller.scrollTop = target;
          // A real finger also dispatches scroll; a bare property write does not,
          // and DSH's follow-the-tail logic keys on the event.
          scroller.dispatchEvent(new Event('scroll', { bubbles: false }));
          return 'scrolled|top=' + Math.round(scroller.scrollTop) + '|target=' + target;
        })();
        """
    }

    static func resumeCompareScript() -> String {
        """
        (function () {
          const before = window.__step15ResumeMark || null;
          const scroller = document.querySelector('[data-conversation-scroll]');
          const box = document.querySelector('[data-composer-input]');
          const after = {
            flowCount: document.querySelectorAll('[data-chat-flow-kind]').length,
            scrollTop: scroller === null ? null : Math.round(scroller.scrollTop),
            scrollHeight: scroller === null ? null : Math.round(scroller.scrollHeight),
            draft: box === null ? '' : (box.innerText || ''),
            scrollY: window.scrollY,
            url: location.href.length,
          };
          return JSON.stringify({
            before: before, after: after,
            sameDocument: before !== null && before.url === after.url,
            sameFlowCount: before !== null && before.flowCount === after.flowCount,
            draftKept: before !== null && before.draft === after.draft,
            scrollKept: before !== null && before.scrollTop === after.scrollTop,
          });
        })();
        """
    }

    /// The send controls as they are right now: every visible primary/stop
    /// button with its accessible label, and whether it is on screen.
    static func sendControlsScript() -> String {
        """
        (function () {
          const buttons = Array.from(document.querySelectorAll('button')).map((el) => {
            const rect = el.getBoundingClientRect();
            return {
              label: (el.getAttribute('aria-label') || '').trim(),
              disabled: el.disabled === true,
              width: Math.round(rect.width), height: Math.round(rect.height),
              x: Math.round(rect.left), y: Math.round(rect.top),
              onScreen: rect.width > 0 && rect.height > 0
                && rect.bottom > 0 && rect.top < window.innerHeight,
            };
          }).filter((entry) => entry.label !== '');
          const queueRows = Array.from(document.querySelectorAll('[class*="_row"]'))
            .filter((el) => el.querySelector('[aria-label="插话发送"], [aria-label="Steer queued message"]') !== null);
          return JSON.stringify({
            buttons: buttons,
            running: document.querySelector('[class*="_running"]') !== null,
            queueRowCount: queueRows.length,
            flowCount: document.querySelectorAll('[data-chat-flow-kind]').length,
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
          });
        })();
        """
    }

    static func queueStateScript() -> String {
        """
        (function () {
          const dock = document.querySelector('[class*="_dock"]');
          const rows = Array.from(document.querySelectorAll('[class*="_row"]'));
          const withActions = rows.map((el) => ({
            text: (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 60),
            actions: Array.from(el.querySelectorAll('button')).map((b) => (b.getAttribute('aria-label') || '').trim()),
          })).filter((entry) => entry.actions.length > 0);
          return JSON.stringify({
            dockPresent: dock !== null,
            rowsWithActions: withActions,
            running: document.querySelector('[class*="_running"]') !== null,
            flowCount: document.querySelectorAll('[data-chat-flow-kind]').length,
          });
        })();
        """
    }

    /// Press the composer's primary button (Send / Queue / Steer / Stop).
    static func pressPrimaryScript() -> String {
        """
        (function () {
          const labels = ['发送消息', '排队发送', '插话发送', '停止生成', 'Send message',
                          'Send queued message', 'Steer message', 'Stop generating'];
          const buttons = Array.from(document.querySelectorAll('button'));
          const candidates = buttons.filter((el) => {
            const label = (el.getAttribute('aria-label') || '').trim();
            if (!labels.some((w) => label === w)) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          });
          if (candidates.length === 0) return 'no-primary';
          // The rightmost wins: the primary sits at the end of the composer row.
          candidates.sort((a, b) => b.getBoundingClientRect().left - a.getBoundingClientRect().left);
          const chosen = candidates[0];
          const label = (chosen.getAttribute('aria-label') || '').trim();
          if (chosen.disabled) return 'disabled:' + label;
          chosen.click();
          return 'pressed:' + label;
        })();
        """
    }

    /// Press the stop control specifically.
    static func pressStopScript() -> String {
        """
        (function () {
          const buttons = Array.from(document.querySelectorAll('button'));
          const stop = buttons.find((el) => {
            const label = (el.getAttribute('aria-label') || '').trim();
            return label === '停止生成' || label === 'Stop generating';
          });
          if (stop === undefined) return 'no-stop-button';
          if (stop.disabled) return 'stop-disabled';
          stop.click();
          return 'pressed-stop';
        })();
        """
    }

    /// Press the steer action of the first queued row.
    static func pressQueueSteerScript() -> String {
        """
        (function () {
          const labels = ['插话发送', 'Steer queued message'];
          const buttons = Array.from(document.querySelectorAll('button'));
          const matches = buttons.filter((el) => {
            const label = (el.getAttribute('aria-label') || '').trim();
            if (!labels.some((w) => label === w)) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          });
          if (matches.length === 0) return 'no-steer-button';
          if (matches[0].disabled) return 'steer-disabled';
          matches[0].click();
          return 'pressed-steer';
        })();
        """
    }

    /// Two quick taps on two different controls.
    ///
    /// The pair is chosen from controls that are always present and whose effect
    /// is observable without changing the conversation: the sidebar toggle (opens
    /// the drawer) and the composer's "+" (opens its menu). Both are counted by
    /// looking at what appeared afterwards.
    static func twoTapsScript() -> String {
        """
        (function () {
          const tapAt = (el) => {
            const rect = el.getBoundingClientRect();
            const init = {
              bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: 1, pointerId: 21, pointerType: 'touch', isPrimary: true,
              clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2,
            };
            el.dispatchEvent(new PointerEvent('pointerdown', init));
            el.dispatchEvent(new PointerEvent('pointerup', init));
            const touchEnd = new Event('touchend', { bubbles: true, cancelable: true });
            el.dispatchEvent(touchEnd);
            el.click();
            return { prevented: touchEnd.defaultPrevented };
          };
          const first = document.querySelector('[class*="_toggle"]');
          const second = document.querySelector('[class*="_newSession"]');
          if (first === null || second === null) {
            return JSON.stringify({ error: 'controls missing',
                                    first: first !== null, second: second !== null });
          }
          const frame = document.querySelector('[class*="_frame"]');
          const collapsedBefore = frame === null ? null : frame.hasAttribute('data-sidebar-collapsed');
          const a = tapAt(first);
          const b = tapAt(second);
          const collapsedAfter = frame === null ? null : frame.hasAttribute('data-sidebar-collapsed');
          return JSON.stringify({
            firstTap: a, secondTap: b,
            collapsedBefore: collapsedBefore,
            collapsedAfter: collapsedAfter,
            firstActed: collapsedBefore !== collapsedAfter,
            secondActed: b.prevented === false,
            gapMs: 1,
          });
        })();
        """
    }

    // MARK: - Plumbing

    private func evaluate(_ script: String) async -> Any? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if error != nil { continuation.resume(returning: nil); return }
                continuation.resume(returning: value)
            }
        }
    }

    private func append(_ record: [String: Any]) {
        var payload = record
        if payload["at"] == nil {
            payload["at"] = ISO8601DateFormatter().string(from: Date())
        }
        records.append(payload)
        flush()
    }

    private func flush() {
        let payload: [String: Any] = [
            "probe": "step15",
            "action": Self.action,
            "device": [
                "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
                "name": UIDevice.current.name,
                "systemVersion": UIDevice.current.systemVersion,
            ],
            "records": records,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    var reportPath: String { reportURL.path }
}
