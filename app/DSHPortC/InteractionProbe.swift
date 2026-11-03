//
//  InteractionProbe.swift
//  DSHPortC
//
//  Step 11's measurement hook for the on-screen interaction questions: page
//  auto-zoom on focus, the keyboard covering the composer, and how much of the
//  screen the debug chrome takes.
//
//  WHY THIS EXISTS
//  ---------------
//  None of the three questions can be answered from the source:
//
//    * Whether iOS WebKit zooms the page when a field is focused depends on the
//      *computed* font size of the focused element at the moment focus happens,
//      which is a runtime fact about the CSS cascade, not something readable
//      from a Swift file.
//    * Whether the composer stays above the keyboard is a fact about the
//      interaction between the keyboard's frame, the web view's frame and
//      `visualViewport` — three values that only exist while the keyboard is up.
//    * How much height the navigation bar and its toolbar take is a SwiftUI
//      layout result.
//
//  So this records the page's own numbers, at named moments, into a JSON file.
//  Every "before/after" figure in REPORT-11.md comes from here.
//
//  WHAT IT IS NOT
//  --------------
//  It decides nothing and asserts nothing. It types when told to, samples when
//  told to, and writes down what it saw. The comparison and the verdicts live in
//  the report, where a reader can check them against the raw numbers.
//
//  GATING
//  ------
//  Nothing here runs unless the app is launched with `-DSHPortEStep11 1`, so a
//  normal launch never reaches this code.
//

import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
final class InteractionProbe: ObservableObject {
    static let shared = InteractionProbe()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEStep11") == 1
    }

    /// Which scripted sequence to run once the page is up.
    ///
    ///   idle        sample once, touch nothing (baseline for the chrome height)
    ///   focus       focus the composer, sample, wait, blur, sample
    ///   type        focus, type five lines, sample with the keyboard up
    ///   send        focus, type, send, sample while the reply streams
    ///   long        scroll a long conversation to the bottom, then focus
    ///   zoom        double-tap the conversation, sample (double-tap zoom check)
    ///
    /// Unrecognised values do nothing, which is the safe default for a hook that
    /// only exists to measure.
    static var action: String {
        UserDefaults.standard.string(forKey: "DSHPortEStep11Action") ?? "idle"
    }

    /// Rotate the app to the orientation named on the command line, before the
    /// scripted sequence runs.
    ///
    /// Rotation is a request, not an order (`requestGeometryUpdate` can refuse a
    /// scene that has not activated yet), so the error is recorded instead of
    /// assumed away. Step 10 established the timing: after the page is up, the
    /// request is honoured; before that it is refused with a message about the
    /// window mode, which is a statement about timing, not about the API.
    static var orientation: String? {
        let raw = UserDefaults.standard.string(forKey: "DSHPortEStep11Rotate") ?? ""
        return raw.isEmpty ? nil : raw
    }

    private func applyOrientation(_ wanted: String) {
        guard wanted != "keep" else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow }
        guard let scene else { return }
        let mask: UIInterfaceOrientationMask = wanted == "landscape" ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            self?.append(["event": "rotation-refused", "wanted": wanted,
                          "error": error.localizedDescription])
        }
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Tag for the output file, so a fresh launch per state does not overwrite
    /// the previous state's evidence (the container survives between launches).
    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tag = UserDefaults.standard.string(forKey: "DSHPortEStep11Tag") ?? ""
        let name = tag.isEmpty ? "DSHPortE-step11.json" : "DSHPortE-step11-\(tag).json"
        return documents.appendingPathComponent(name)
    }()

    private var webView: WKWebView?
    private var started = false
    private var records: [[String: Any]] = []
    /// Samples taken while a turn is running, tagged by kind.
    private var pollTimer: Timer?

    // MARK: - Setup

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        append(["event": "registered", "action": Self.action])
    }

    /// Record one network-layer fact about the navigation.
    ///
    /// The page came up empty twice -- `<html><head></head><body></body></html>`
    /// as the entire document -- while the same URL in the simulator's Safari
    /// rendered the whole UI. A DOM probe cannot tell "no response arrived" from
    /// "a response arrived and WebKit did not navigate", so the navigation
    /// callbacks record the status codes and the final URL. Only a probe launch
    /// installs this; it changes no behaviour.
    func noteNavigation(_ event: String, _ detail: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        var record: [String: Any] = ["event": "navigation", "phase": event]
        record.merge(detail) { _, new in new }
        append(record)
    }

    /// Run the scripted sequence named on the command line.
    func runIfConfigured() {
        guard Self.isEnabled, !started else { return }
        started = true
        Task { @MainActor in
            // The plugin bundles mount after `didFinish`; measuring before the
            // composer exists would record a page with no conversation in it.
            // Dump the page every few seconds while waiting. A silent wait was
            // exactly how the first stuck launch produced an evidence file with
            // one line in it: no way to tell a stuck page from a missing flag.
            for _ in 0..<40 {
                if let present = await evaluate("document.querySelector('[data-composer-input]') !== null") as? Bool, present { break }
                append(["event": "waiting-for-composer",
                        "page": (await evaluate(Self.pageDiagnosticsScript())) ?? "nil"])
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            let ready = (await evaluate("document.querySelector('[data-composer-input]') !== null") as? Bool) ?? false
            if !ready {
                // Record WHY rather than exiting quietly. A probe file with only
                // a `registered` event is indistinguishable from "the flag never
                // arrived"; a page dump is not. This fired for real once and the
                // cause was a stuck page, not a missing flag.
                append(["event": "composer-never-appeared",
                        "page": (await evaluate(Self.pageDiagnosticsScript())) ?? "nil"])
            } else {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            // Rotation first, then a settle, so every sample in this run belongs
            // to one orientation. Recorded either way: a refused request would
            // otherwise be invisible and the numbers would carry a wrong label.
            if let wanted = Self.orientation {
                applyOrientation(wanted)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                append(["event": "orientation-requested", "wanted": wanted,
                        "innerWidth": (await evaluate("window.innerWidth")) ?? "nil",
                        "innerHeight": (await evaluate("window.innerHeight")) ?? "nil"])
            }
            switch Self.action {
            case "idle":   await runIdle()
            case "focus":  await runFocus()
            case "type":   await runType()
            case "send":   await runSend()
            case "long":   await runLong()
            case "zoom":   await runZoom()
            default:       await sample(label: "unrecognised-action")
            }
            append(["event": "done", "action": Self.action])
        }
    }

    // MARK: - Sequences

    /// Sample the page with nothing focused and no keyboard.
    private func runIdle() async {
        await sample(label: "idle")
        // Second sample after a beat, so a value that is still settling can be
        // told apart from a stable one.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await sample(label: "idle-settled")
    }

    /// Focus the composer, watch the page, then blur it and watch again.
    ///
    /// The point is the whole arc: `visualViewport.scale` must be 1 before
    /// focus, during focus, and after blur. A value that jumps to 1.6 on focus
    /// and stays there is exactly the bug the task names.
    private func runFocus() async {
        await sample(label: "before-focus")
        _ = try? await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 900_000_000)
        await sample(label: "focus-0.9s")
        try? await Task.sleep(nanoseconds: 900_000_000)
        await sample(label: "focus-1.8s")
        tickFor(seconds: 3, label: "focus-hold")
        _ = try? await evaluate(Self.blurScript())
        try? await Task.sleep(nanoseconds: 900_000_000)
        await sample(label: "after-blur")
    }

    /// Focus, type five lines, and hold the keyboard up long enough to measure.
    private func runType() async {
        await sample(label: "before-focus")
        _ = try? await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 800_000_000)
        _ = try? await evaluate(Self.insertFiveLinesScript())
        try? await Task.sleep(nanoseconds: 800_000_000)
        await sample(label: "typed-5-lines")
        tickFor(seconds: 3, label: "typed-hold")
        // Blur, then measure that the layout came back without a gap.
        _ = try? await evaluate(Self.blurScript())
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await sample(label: "after-blur")
    }

    /// Type a prompt, send it, and sample while the reply arrives.
    ///
    /// "The last message is fully visible" is a claim about a conversation with
    /// content in it, so the keyboard measurement has to happen on a real turn
    /// rather than on an empty composer.
    private func runSend() async {
        await sample(label: "before-focus")
        _ = try? await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = try? await evaluate(Self.insertPromptScript())
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = try? await evaluate(Self.pressSendScript())
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await sample(label: "sent-keyboard-up-1.2s")
        tickFor(seconds: 6, label: "streaming-keyboard-up")
        // Then collapse the keyboard and check the layout came back.
        _ = try? await evaluate(Self.blurScript())
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "after-blur")
    }

    /// Build a long conversation, scroll it to its bottom, then focus.
    ///
    /// WHY IT BUILDS ONE. The first version of this plan scrolled whatever was on
    /// screen, which after a fresh launch is the hero page with no messages at
    /// all — `flowItemCount` 0, `lastMessage` nil, and the measurement proved
    /// nothing about a long conversation. The state the task asks about ("长对话
    /// 滚到底") only exists after several turns, so this sends them.
    ///
    /// Each turn waits for the reply to finish before the next one starts: a
    /// prompt sent into a running turn is a different code path (steering), and
    /// the point here is an ordinary transcript scrolled to its end.
    private func runLong() async {
        await sample(label: "before-turns")
        // Three ordinary turns. The mock server keys on STREAMTEST and streams a
        // dozen chunks, so each turn both fills the transcript and takes long
        // enough that "wait for the reply" is a real wait.
        for turn in 1...3 {
            _ = try? await evaluate(Self.focusComposerScript())
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await evaluate(Self.insertTextScript("STREAMTEST 长对话第 \(turn) 轮"))
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await evaluate(Self.pressSendScript())
            _ = try? await waitForReply(timeout: 45)
            _ = try? await evaluate(Self.blurScript())
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        await sample(label: "after-turns")

        // Now scroll the transcript to its newest message and focus.
        _ = try? await evaluate(Self.scrollToBottomScript())
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await sample(label: "scrolled-to-bottom")
        _ = try? await evaluate(Self.focusComposerScript())
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await sample(label: "long-focus-1.2s")
        tickFor(seconds: 3, label: "long-focus-hold")
        _ = try? await evaluate(Self.blurScript())
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await sample(label: "long-after-blur")
    }

    /// Wait until the page stops showing a running turn.
    ///
    /// `data-chat-following-tail` and the running indicator are DSH's own markers
    /// for "a reply is still arriving"; polling the flow items' count is the
    /// other half. Both are read from the page, not assumed.
    private func waitForReply(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let still = await evaluate("""
            (function () {
              const running = document.querySelector('[class*="_running"]');
              const items = document.querySelectorAll('[data-chat-flow-kind]').length;
              return JSON.stringify({ running: running !== null, items: items });
            })();
            """) as? String
            if let still, let data = still.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let running = parsed["running"] as? Bool, running == false {
                return true
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }

    /// Double-tap the conversation and see whether the page zooms.
    ///
    /// Dispatched as two full pointer sequences 90 ms apart, which is the shape
    /// WebKit's double-tap recogniser looks for. If a CSS rule stops the gesture,
    /// the second tap's series is what the page sees; measuring the scale before
    /// and after is the only way to know whether it acted.
    private func runZoom() async {
        await sample(label: "before-double-tap")
        _ = try? await evaluate(Self.doubleTapScript())
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await sample(label: "after-double-tap")
    }

    // MARK: - Polling

    /// Sample repeatedly for a few seconds under a label prefix.
    ///
    /// Used where the interesting state is not a single instant — a streaming
    /// reply grows, and the keyboard inset animates in. One sample taken at the
    /// wrong moment would report a state that never existed on screen for long.
    private func tickFor(seconds: Int, label: String) {
        pollTimer?.invalidate()
        var remaining = seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                remaining -= 1
                await self.sample(label: "\(label)-t\(seconds - remaining)")
                if remaining <= 0 { timer.invalidate() }
            }
        }
    }

    // MARK: - Sampling

    private func sample(label: String) async {
        let dom = await evaluate(Self.measureScript())
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
        record["keyboard"] = keyboardFacts()
        append(record)
    }

    /// What the app itself thinks its geometry is.
    ///
    /// The web view's own frame is the number that matters for the keyboard
    /// question: DSH lays itself out inside whatever rectangle it is given, so a
    /// web view that keeps full height while the keyboard covers its lower third
    /// is a layout bug in the shell, not in the page.
    /// What sits between the keyboard and the page, straight from UIKit.
    ///
    /// The question "is the `^ v ✓` strip gone" has no DOM answer: the strip is a
    /// UIKit view owned by WebKit's own input content, not part of the page. The
    /// only witness is the responder chain — walk the web view's subviews for a
    /// first responder, and record its `inputAccessoryView` with its height. A
    /// height of 0 (or no accessory at all) is the strip being absent; 44 pt is
    /// the strip being present.
    private func keyboardFacts() -> [String: Any] {
        guard let webView else { return ["webView": "absent"] }
        var facts: [String: Any] = [:]
        func walk(_ view: UIView, depth: Int) {
            if depth > 24 { return }
            if view.isFirstResponder {
                facts["firstResponder"] = String(describing: type(of: view))
                if let accessory = view.inputAccessoryView {
                    facts["accessoryPresent"] = true
                    facts["accessoryHeight"] = Double(accessory.frame.height)
                    facts["accessoryClass"] = String(describing: type(of: accessory))
                    facts["accessorySubviews"] = accessory.subviews.count
                } else {
                    facts["accessoryPresent"] = false
                    facts["accessoryHeight"] = 0.0
                }
                let item = view.inputAssistantItem
                facts["assistantLeadingGroups"] = item.leadingBarButtonGroups.count
                facts["assistantTrailingGroups"] = item.trailingBarButtonGroups.count
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(webView, depth: 0)
        // The keyboard's own frame, as UIKit reports it, so the report can state
        // the keyboard height independently of `visualViewport`.
        let screenHeight = UIScreen.main.bounds.height
        let keyboardFrames = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .map { $0.convert($0.bounds, to: nil) }
        facts["screenHeight"] = Double(screenHeight)
        facts["windowCount"] = keyboardFrames.count
        return facts
    }

    private func appFacts() -> [String: Any] {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var facts: [String: Any] = [
            "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "screenHeight": Double((window?.windowScene?.screen.bounds.height) ?? 0),
            "screenWidth": Double((window?.windowScene?.screen.bounds.width) ?? 0),
        ]
        if let window {
            facts["windowHeight"] = Double(window.bounds.height)
            facts["windowWidth"] = Double(window.bounds.width)
            facts["safeAreaTop"] = Double(window.safeAreaInsets.top)
            facts["safeAreaBottom"] = Double(window.safeAreaInsets.bottom)
        }
        if let webView, let superview = webView.superview {
            let rect = webView.convert(webView.bounds, to: window)
            facts["webViewFrame"] = [
                "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                "width": Double(rect.width), "height": Double(rect.height),
            ]
            facts["webViewBottom"] = Double(rect.maxY)
            _ = superview
        }
        return facts
    }

    // MARK: - Scripts

    /// Focus the composer the way a finger would.
    ///
    /// `click()` rather than `.focus()`: WebKit decides on the auto-zoom from a
    /// user gesture, and a programmatic `focus()` can skip the gesture path
    /// entirely, which would make the bug invisible to this probe.
    private static func focusComposerScript() -> String {
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

    /// Drop focus, which is what makes the keyboard go away.
    ///
    /// Blurring alone leaves the keyboard up in some WebKit versions; tapping a
    /// non-editable part of the page is the gesture a person uses, so both.
    private static func blurScript() -> String {
        """
        (function () {
          const active = document.activeElement;
          if (active && active.blur) active.blur();
          const target = document.querySelector('[data-conversation-scroll]') || document.body;
          const rect = target.getBoundingClientRect();
          const init = {
            bubbles: true, cancelable: true, composed: true, button: 0,
            buttons: 1, pointerId: 2, pointerType: 'touch', isPrimary: true,
            clientX: rect.left + 20, clientY: rect.top + 20,
          };
          target.dispatchEvent(new PointerEvent('pointerdown', init));
          target.dispatchEvent(new PointerEvent('pointerup', init));
          target.dispatchEvent(new MouseEvent('click', init));
          return 'blurred:' + (document.activeElement !== null ? document.activeElement.tagName : 'none');
        })();
        """
    }

    /// Insert five lines through the composer's real paste path.
    ///
    /// Same reasoning as UIDriver's `typeAndSendScript`: this composer is a
    /// Lexical editor, so setting `textContent` changes the DOM without changing
    /// the editor's state. A synthetic paste event reaches DSH's own
    /// `PASTE_COMMAND` handler and goes through the same insert path a real paste
    /// takes, which is also what makes the composer grow the way it does for a
    /// person typing five lines.
    private static func insertFiveLinesScript() -> String {
        let text = "第一行：多行输入测试\\n第二行\\n第三行\\n第四行\\n第五行：最后一行"
        return insertTextScript(text)
    }

    /// The prompt the scripted send uses. The mock model server keys on
    /// STREAMTEST, so the reply streams and the conversation has content.
    private static func insertPromptScript() -> String {
        insertTextScript("STREAMTEST 键盘可见性测试")
    }

    private static func insertTextScript(_ text: String) -> String {
        """
        (function () {
          const text = '\(text)';
          const box = document.querySelector('[data-composer-input]')
            || document.querySelector('[contenteditable="true"]');
          if (box === null) return 'no-composer';
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
            if (paste.defaultPrevented) {
              return 'paste|rendered=' + (box.innerText || '').length;
            }
          } catch (error) { /* not constructible here */ }
          document.execCommand('insertText', false, text);
          return 'execCommand|rendered=' + (box.innerText || '').length;
        })();
        """
    }

    /// Press the composer's send control.
    private static func pressSendScript() -> String {
        """
        (function () {
          const buttons = Array.from(document.querySelectorAll('button'));
          const send = buttons.find((b) => {
            const label = (b.getAttribute('aria-label') || b.title || '').trim();
            return label === '发送消息' || label === 'Send message';
          });
          if (send === undefined) return 'no-send-button';
          if (send.disabled) return 'send-disabled';
          send.click();
          return 'clicked-send';
        })();
        """
    }

    /// Put the conversation at its newest message.
    private static func scrollToBottomScript() -> String {
        """
        (function () {
          const scroller = document.querySelector('[data-conversation-scroll]');
          if (scroller === null) return 'no-scroller';
          const inner = scroller.scrollHeight > scroller.clientHeight ? scroller : null;
          const target = inner ?? document.scrollingElement;
          target.scrollTop = target.scrollHeight;
          return 'scrolled|top=' + Math.round(target.scrollTop)
            + '|height=' + Math.round(target.scrollHeight)
            + '|client=' + Math.round(target.clientHeight);
        })();
        """
    }

    /// Two full tap sequences 90 ms apart, on the middle of the conversation.
    private static func doubleTapScript() -> String {
        """
        (function () {
          const target = document.querySelector('[data-conversation-scroll]') || document.body;
          const rect = target.getBoundingClientRect();
          const x = rect.left + rect.width / 2;
          const y = rect.top + rect.height / 2;
          const tap = () => {
            const init = {
              bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: 1, pointerId: 7, pointerType: 'touch', isPrimary: true,
              clientX: x, clientY: y,
            };
            target.dispatchEvent(new PointerEvent('pointerdown', init));
            target.dispatchEvent(new PointerEvent('pointerup', init));
            target.dispatchEvent(new MouseEvent('mousedown', init));
            target.dispatchEvent(new MouseEvent('mouseup', init));
            target.dispatchEvent(new MouseEvent('click', init));
          };
          tap();
          const before = (window.visualViewport || {}).scale || 1;
          return new Promise((resolve) => {
            setTimeout(() => {
              tap();
              setTimeout(() => {
                resolve(JSON.stringify({
                  before: before,
                  after: (window.visualViewport || {}).scale || 1,
                  dispatched: 2,
                }));
              }, 320);
            }, 90);
          });
        })();
        """
    }

    /// A page dump for the case where the composer never shows up.
    ///
    /// Without this, a stuck page produces an evidence file with one line in it
    /// and no way to tell that apart from a launch argument that never arrived.
    private static func pageDiagnosticsScript() -> String {
        """
        (function () {
          const scroller = document.querySelector('[data-conversation-scroll]');
          return JSON.stringify({
            urlHasToken: location.href.indexOf('token=') >= 0,
            urlLength: location.href.length,
            htmlLength: document.documentElement === null ? -1 : document.documentElement.outerHTML.length,
            htmlHead: document.documentElement === null ? null
              : document.documentElement.outerHTML.replace(/\\s+/g, ' ').slice(0, 260),
            bodyPresent: document.body !== null,
            headPresent: document.head !== null,
            cookieCount: (document.cookie || '').length,
            title: document.title,
            bodyLength: (document.body.innerText || '').length,
            bodyHead: (document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 300),
            rootChildren: document.getElementById('root') === null
              ? -1 : document.getElementById('root').children.length,
            composerCount: document.querySelectorAll('[data-composer-input]').length,
            editableCount: document.querySelectorAll('[contenteditable="true"]').length,
            textareaCount: document.querySelectorAll('textarea').length,
            scrollerPresent: scroller !== null,
            vvHeight: (window.visualViewport || {}).height,
            scale: (window.visualViewport || {}).scale,
            readyState: document.readyState,
          });
        })();
        """
    }

    /// The measurement itself: everything the three questions need, from the DOM.
    ///
    /// The values are read at one instant on purpose. Reading `innerHeight` and
    /// then `visualViewport.height` two frames apart can catch the keyboard mid
    /// animation and produce a combination that never existed.
    static func measureScript() -> String {
        """
        (function () {
          const vv = window.visualViewport || null;
          const composer = document.querySelector('[data-composer-input]')
            || document.querySelector('[contenteditable="true"]');
          const out = {
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            dpr: window.devicePixelRatio,
            scale: vv === null ? 1 : vv.scale,
            vvWidth: vv === null ? null : vv.width,
            vvHeight: vv === null ? null : vv.height,
            vvOffsetTop: vv === null ? null : vv.offsetTop,
            vvOffsetLeft: vv === null ? null : vv.offsetLeft,
            vvPageTop: vv === null ? null : vv.pageTop,
            docClientWidth: document.documentElement.clientWidth,
            docScrollWidth: document.documentElement.scrollWidth,
            docScrollHeight: document.documentElement.scrollHeight,
            scrollX: window.scrollX,
            scrollY: window.scrollY,
            activeElement: document.activeElement === null ? null : document.activeElement.tagName,
            activeIsComposer: document.activeElement === composer,
            // The computed font size of the focused field, which is the fact iOS
            // WebKit's focus-zoom keys on. 16px is the threshold.
            composerFontSize: composer === null ? null
              : parseFloat(getComputedStyle(composer).fontSize),
            composerHeight: composer === null ? null
              : Math.round(composer.getBoundingClientRect().height),
          };
          if (composer !== null) {
            const rect = composer.getBoundingClientRect();
            out.composerRect = {
              top: Math.round(rect.top), bottom: Math.round(rect.bottom),
              left: Math.round(rect.left), right: Math.round(rect.right),
              width: Math.round(rect.width), height: Math.round(rect.height),
            };
            // Visible if the composer's bottom edge is above the visual viewport
            // bottom. `vvOffsetTop` is 0 unless the page itself is scrolled within
            // the visual viewport, but including it keeps the test honest when it
            // is not.
            const vvBottom = (vv === null ? window.innerHeight : vv.height + vv.offsetTop);
            out.composerVisible = rect.bottom <= vvBottom + 0.5 && rect.top >= vv.offsetTop - 0.5;
            out.composerBottomVsVv = Math.round((vvBottom - rect.bottom) * 10) / 10;
          }
          // The newest message: the flow item with the greatest bottom edge. Any
          // selector keyed on a class name would break on the next bundle; the
          // flow markers are data attributes DSH sets deliberately.
          const items = Array.from(document.querySelectorAll('[data-chat-flow-kind]'));
          let last = null;
          for (const el of items) {
            const rect = el.getBoundingClientRect();
            if (rect.height <= 0) continue;
            if (last === null || rect.bottom > last.rect.bottom) last = { el: el, rect: rect };
          }
          if (last !== null) {
            const vvBottom = (vv === null ? window.innerHeight : vv.height + vv.offsetTop);
            out.lastMessage = {
              kind: last.el.getAttribute('data-chat-flow-kind'),
              top: Math.round(last.rect.top), bottom: Math.round(last.rect.bottom),
              height: Math.round(last.rect.height),
              inViewport: last.rect.bottom <= vvBottom + 0.5,
              bottomVsVv: Math.round((vvBottom - last.rect.bottom) * 10) / 10,
              text: (last.el.innerText || '').replace(/\\\\s+/g, ' ').trim().slice(0, 60),
            };
          } else {
            out.lastMessage = null;
          }
          out.flowItemCount = items.length;
          // The scroll container's own geometry: if the composer overlaps it, the
          // page laid itself out under the keyboard instead of above it.
          const scroller = document.querySelector('[data-conversation-scroll]');
          if (scroller !== null) {
            const rect = scroller.getBoundingClientRect();
            out.scroller = {
              top: Math.round(rect.top), bottom: Math.round(rect.bottom),
              height: Math.round(rect.height),
              scrollTop: Math.round(scroller.scrollTop),
              scrollHeight: Math.round(scroller.scrollHeight),
              clientHeight: Math.round(scroller.clientHeight),
              atBottom: Math.abs(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop) < 2,
            };
          }
          // The chrome: DSH's own top area inside the page. Comparing its height
          // with the window's is how the report says how much the shell's bar cost.
          const frame = document.querySelector('[data-sidebar-collapsed], [class*="_frame"]');
          if (frame !== null) {
            const rect = frame.getBoundingClientRect();
            out.frame = {
              top: Math.round(rect.top), bottom: Math.round(rect.bottom),
              height: Math.round(rect.height),
              gridTemplateColumns: getComputedStyle(frame).gridTemplateColumns || '',
            };
          }
          // Body background: a rubber-band overscroll shows through as this colour,
          // so a white flash is a white `body` behind a dark app.
          const bodyStyle = getComputedStyle(document.body);
          out.bodyBackground = bodyStyle.backgroundColor;
          const htmlStyle = getComputedStyle(document.documentElement);
          out.htmlBackground = htmlStyle.backgroundColor;
          out.bodyOverscrollBehavior = bodyStyle.overscrollBehavior;
          out.htmlOverscrollBehavior = htmlStyle.overscrollBehavior;
          out.touchActionBody = bodyStyle.touchAction;
          out.userSelectBody = bodyStyle.userSelect || bodyStyle.webkitUserSelect;
          out.webkitTouchCallout = bodyStyle.webkitTouchCallout;
          out.webkitTapHighlight = bodyStyle.webkitTapHighlightColor;
          // The viewport meta as the page actually received it, and whether the
          // page declares a maximum scale that forbids pinch-zoom.
          const meta = document.querySelector('meta[name="viewport"]');
          out.viewportMeta = meta === null ? null : meta.getAttribute('content');
          out.visibleMetaText = meta === null ? null : meta.outerHTML;
          out.hasUserScriptMeta = document.querySelectorAll('meta[name="viewport"]').length;
          return JSON.stringify(out);
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

    private func waitFor(javaScript: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flag = await evaluate(javaScript) as? Bool, flag { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
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
            "probe": "step11",
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
