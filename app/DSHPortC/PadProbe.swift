//
//  PadProbe.swift
//  DSHPortC
//
//  Step 10's measurement hook for the iPad. Writes
//  Documents/DSHPortE-padprobe.json, and nothing here runs unless the app is
//  launched with `-DSHPortEPadProbe 1` — a normal launch never reaches it.
//
// WHY THIS EXISTS
// ---------------
// The iPad questions are not answerable from the source:
//
//   * DSH's layout store picks a narrow or wide arrangement from the frame
//     element's measured width (SIDEBAR_AUTO_COLLAPSE = 1024 in
//     dsh-client-ui-layout/lib/client.js). On the phone the viewport is 402 pt,
//     so it is always narrow and the session rows never enter the DOM at all.
//     On the iPad the answer depends on orientation and on whether the window is
//     full width, so it has to be read at runtime, in each state.
//   * Whether a ⌘-chord reaches the page is a fact about iPadOS and WKWebView,
//     not about DSH. The only witness is a listener inside the page recording
//     what it actually received.
//   * Rotation and backgrounding have to be observed as they happen; polling
//     after the fact sees only the end state.
//
// So this records, on demand and on every lifecycle/orientation transition, the
// measurements above plus a DOM snapshot of the sidebar and the composer. Every
// number in the report's iPad section comes from this file.
//
// WHAT IT IS NOT
// --------------
// It does not decide anything, and it does not click. Gestures come from the UI
// test (app/DSHPortCUITests/PadDriveTests.swift) and from a person; this only
// records what the app and its web view then looked like.
//

import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
final class PadProbe: ObservableObject {
    static let shared = PadProbe()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEPadProbe") == 1
    }

    /// Approximate split-screen widths, for the case the simulator cannot enter
    /// Split View programmatically.
    ///
    /// Setting this constrains the web view's width to a fraction of the window
    /// so DSH's own layout store sees a narrower frame — which is the part of
    /// Split View that matters for layout. It is NOT Split View: the app still
    /// owns the whole window, iPadOS is not resizing us, and the OS-level
    /// keyboard/inset behaviour is the full-screen one. The report says so where
    /// it quotes these numbers.
    ///
    /// Published because the sweep below changes it while the app is running:
    /// SwiftUI has to re-lay out for the narrower frame to reach the web view,
    /// and a `static let` read once at view-build time could not do that.
    @Published var fraction: Double? = nil

    /// The fraction named on the command line, before the sweep overrides it.
    static var commandLineFraction: Double? {
        guard isEnabled else { return nil }
        let raw = UserDefaults.standard.string(forKey: "DSHPortEPadLayoutFraction") ?? ""
        guard let value = Double(raw), value > 0.1, value < 1.0 else { return nil }
        return value
    }

    /// What the view should use right now. The sweep takes precedence while it
    /// runs; otherwise the command-line value (usually nothing) applies.
    static var layoutFraction: Double? {
        shared.fraction ?? commandLineFraction
    }

    private var webView: WKWebView?
    private var sweeps: [[String: Any]] = []
    private var started = false
    /// Set by `attemptRotationIfConfigured`, so a second navigation cannot run the
    /// attempt twice and record the same refusal twice.
    private var rotationAttempted = false
    /// Same guard for the session-row press.
    private var pressStarted = false
    /// Same guard for the keyboard chord probe.
    private var keyboardStarted = false
    /// Set when the app has actually been backgrounded. The resume turn waits for
    /// this, because `didBecomeActive` also fires on first activation.
    private var wentToBackground = false
    /// Set once the resume turn has been dispatched. `didBecomeActive` also fires
    /// on first activation, and a second prompt would be a different measurement.
    private var resumeTurnSent = false
    private let observations = NSMutableArray()

    /// The probe file's name, with the tag when one was given.
    ///
    /// One file per stage rather than one shared file, because a UI test launches
    /// the app fresh for each state and the container survives between launches:
    /// a shared file would be overwritten by the next stage and the report would
    /// be quoting whatever ran last. `-DSHPortEPadProbeTag 01-portrait-full` makes
    /// the file `DSHPortE-padprobe-01-portrait-full.json`.
    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tag = UserDefaults.standard.string(forKey: "DSHPortEPadProbeTag") ?? ""
        let name = tag.isEmpty ? "DSHPortE-padprobe.json" : "DSHPortE-padprobe-\(tag).json"
        return documents.appendingPathComponent(name)
    }()

    // MARK: - Setup

    /// Install the in-page recorder before the document exists, so no keystroke
    /// or layout change can happen before it is listening.
    static func recorderBootstrapScript() -> String {
        """
        (function () {
          if (window.__padProbe !== undefined) return;
          const keys = [];
          const MAX = 200;
          // Recorded whether or not DSH handles them: the question is what
          // reaches the page at all, which is upstream of any handler.
          const record = (event) => {
            if (keys.length >= MAX) return;
            const target = event.target;
            keys.push({
              type: event.type,
              code: event.code || '',
              key: event.key || '',
              meta: !!event.metaKey,
              ctrl: !!event.ctrlKey,
              alt: !!event.altKey,
              shift: !!event.shiftKey,
              repeated: !!event.repeat,
              defaultPrevented: !!event.defaultPrevented,
              target: target && target.tagName ? String(target.tagName) : '?',
              editable: !!(target && (target.isContentEditable || target.tagName === 'TEXTAREA' || target.tagName === 'INPUT')),
              t: Date.now(),
            });
          };
          for (const type of ['keydown', 'keyup', 'beforeinput']) {
            window.addEventListener(type, record, true);
          }
          window.addEventListener('resize', () => {
            window.__padProbeResizes = (window.__padProbeResizes || 0) + 1;
          });
          window.__padProbe = {
            keys,
            drainKeys: () => { const out = keys.slice(); keys.length = 0; return out; },
          };
        })();
        """
    }

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        start()
    }

    private func start() {
        guard !started else { return }
        started = true

        var base: [String: Any] = [:]
        base["enabledAt"] = ISO8601DateFormatter().string(from: Date())
        base["layoutFraction"] = Self.layoutFraction as Any? ?? NSNull()
        base["idiom"] = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        base["systemVersion"] = UIDevice.current.systemVersion
        base["model"] = UIDevice.current.model
        sweeps.append(["event": "started", "facts": base])
        flush()

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let center = NotificationCenter.default
        observe(center, UIDevice.orientationDidChangeNotification, label: "orientation-changed")
        observe(center, UIApplication.didEnterBackgroundNotification, label: "did-enter-background")
        // The resume turn has to know a backgrounding actually happened; see
        // runResumeTurnIfConfigured.
        let bg = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wentToBackground = true }
        }
        observations.add(bg)
        observe(center, UIApplication.willEnterForegroundNotification, label: "will-enter-foreground")
        observe(center, UIApplication.didBecomeActiveNotification, label: "did-become-active")
        observe(center, UIScene.didActivateNotification, label: "scene-did-activate")
        observe(center, UIScene.willDeactivateNotification, label: "scene-will-deactivate")

        // Resuming can be a second turn, and only the lifecycle says so.
        //
        // Measured while writing the resume check: calling `simctl launch` on an
        // app that is merely backgrounded brings it forward WITHOUT restarting it,
        // so `onReady` does not fire again and nothing hanging off it runs. The
        // first run of scripts/pad-resume.py therefore reported "turn 2 did not
        // complete" for an app that had simply never been asked to send.
        if UserDefaults.standard.integer(forKey: "DSHPortEPadResumeTurn") == 1 {
            let token = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runResumeTurnIfConfigured() }
            }
            observations.add(token)
            // Record that the hook is installed. Without this, "the resume turn was
            // never dispatched" and "the launch argument never arrived" look
            // identical in the file — and they did, on the first run of this.
            sweeps.append(["event": "resume-hook-installed",
                           "at": ISO8601DateFormatter().string(from: Date())])
            flush()
        }

        // A coarse heartbeat too: a rotation sweep can land before DSH's
        // ResizeObserver has re-laid out, and a single sample at that instant
        // would record a half-settled frame. The heartbeat is what lets the
        // report quote the settled numbers instead of a transient.
        Task { @MainActor in
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.sweep(label: "heartbeat")
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, label: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sweep(label: label)
                // Rotations settle over a couple of runloop turns; take a second
                // sample so the file has both the immediate and the settled one.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.sweep(label: label + "+1.5s")
            }
        }
        observations.add(token)
    }

    // MARK: - Resume turn

    /// After the app comes back to the foreground, send one more turn.
    ///
    /// What this is for: whether the DSH page is still usable after a background
    /// trip. A WKWebView whose content process was reclaimed comes back blank, and
    /// a lifecycle log alone cannot tell that apart from a working page — only a
    /// turn that actually completes can.
    ///
    /// Guarded by `resumeTurnSent`, because `didBecomeActive` fires on the first
    /// activation too, and a second identical prompt would look like a resume that
    /// worked when nothing had been resumed.
    private func runResumeTurnIfConfigured() {
        guard Self.isEnabled,
              UserDefaults.standard.integer(forKey: "DSHPortEPadResumeTurn") == 1 else { return }
        // THE GATE IS "HAS BEEN IN THE BACKGROUND", NOT "HAS NOT SENT YET".
        // `didBecomeActive` also fires on first activation, so a plain
        // `!resumeTurnSent` guard burned the one chance before there was anything
        // to resume — measured: the second run of scripts/pad-resume.py recorded
        // the hook as installed, the background/foreground transitions, and no
        // resume-turn event at all. Requiring an observed backgrounding first is
        // what makes the event mean what its name says.
        guard wentToBackground, !resumeTurnSent else { return }
        resumeTurnSent = true
        Task { @MainActor in
            // The page needs a moment to repaint after activation before the
            // composer can take a keystroke.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            sweep(label: "resume-before-turn")
            guard let prompt = UserDefaults.standard.string(forKey: "DSHPortEPadResumePrompt"),
                  !prompt.isEmpty else {
                sweeps.append(["event": "resume-turn",
                               "result": "no-prompt-configured",
                               "at": ISO8601DateFormatter().string(from: Date())])
                flush()
                return
            }
            UIDriver.shared.runScriptedPrompt(prompt, keyword: "STREAMTEST-COMPLETE")
            sweeps.append(["event": "resume-turn",
                           "result": "dispatched",
                           "prompt": prompt,
                           "at": ISO8601DateFormatter().string(from: Date())])
            flush()
        }
    }

    // MARK: - Rotation

    /// Rotate the scene to an orientation named by `-DSHPortEPadRotate`, then take
    /// a settled sweep.
    ///
    /// THIS DOES WORK, BUT NOT WHEN CALLED EARLY. The first attempt rotated
    /// nothing and recorded "当前窗口模式不允许以编程方式更改界面方向"; the same call
    /// after the page existed and the scene was active rotated the iPad to
    /// landscapeRight, 820 -> 1180 pt. So the wait below is not politeness: a
    /// geometry request issued before the scene has a key window is refused, and
    /// the refusal is about the timing rather than about the API.
    ///
    /// This is what makes the report's landscape numbers real screen states rather
    /// than a second build: `scripts/pad-state.py --rotate landscape` asks for the
    /// rotation and then photographs the same binary that rendered portrait.
    /// `scripts/build-pad-landscape.sh` (a landscape-only build) exists as the
    /// fallback for a case where a rotation is refused — it is no longer needed for
    /// the measurements in REPORT-10, and is kept because it is the only other route
    /// and cost one script.
    ///
    /// The earlier version walked a *sequence* of stages in one launch, changing the
    /// width between them. That was abandoned for two measured reasons worth
    /// remembering:
    ///
    ///   * `onReady` fires once per navigation, and the web view finishes more than
    ///     once, so three stage loops ran at once and the recorded widths were a
    ///     mixture of two stages — 78 "stage" sweeps for a 7-stage plan, with the
    ///     label saying one thing and the geometry another.
    ///   * the outside script had to poll for a marker file and photograph inside
    ///     that window, hoping the frame it caught was the settled one. One launch
    ///     per state removes the race entirely, and is what scripts/pad-state.py does.
    func attemptRotationIfConfigured() {
        guard Self.isEnabled,
              let wanted = UserDefaults.standard.string(forKey: "DSHPortEPadRotate"),
              !wanted.isEmpty,
              !rotationAttempted else { return }
        rotationAttempted = true
        Task { @MainActor in
            // Not before the page exists: a scene with no key window accepts
            // nothing, and the refusal would then be about the wrong cause.
            _ = try? await waitFor(
                javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                timeout: 300
            )
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            apply(orientation: wanted, fraction: Self.commandLineFraction)
            // The rotation and the (optional) width change both take a few frames,
            // and DSH's own ResizeObserver needs a turn after that before the
            // layout it settles on is the one worth recording.
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            sweep(label: "after-rotation-attempt")
        }
    }

    private func apply(orientation: String, fraction: Double?) {
        self.fraction = fraction
        guard orientation != "keep", let scene = keyWindow?.windowScene else { return }
        let mask: UIInterfaceOrientationMask = orientation == "landscape" ? .landscape : .portrait
        // The error handler is not decoration. On this SDK `requestGeometryUpdate`
        // is a request, not an order, and a refused one is silent otherwise --
        // the app simply stays where it was and every measurement taken
        // afterwards is labelled with an orientation that never happened.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            self?.recordGeometryError(mask == .landscape ? "landscape" : "portrait",
                                      error.localizedDescription)
        }
        // SwiftUI re-asks the scene what it supports on the next layout pass; a
        // geometry request issued outside that pass can be dropped without ever
        // reaching the handler.
        keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func recordGeometryError(_ wanted: String, _ message: String) {
        sweeps.append([
            "event": "geometry-update-refused",
            "wanted": wanted,
            "error": message,
            "at": ISO8601DateFormatter().string(from: Date()),
        ])
        flush()
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private func waitFor(javaScript: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await evaluateAwaitable(javaScript), (value as? Bool) == true { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func evaluateAwaitable(_ script: String) async throws -> Any? {
        guard let webView else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    // MARK: - Session-row press

    /// Press a session row the way a finger would, and record what changed.
    ///
    /// Step 10 asks whether the session list can be "directly clicked open" on the
    /// iPad, where on the phone the same list is a 56 px rail with no rows in the
    /// DOM at all. The layout store's decision is recorded by the sweeps; this
    /// answers the separate question of whether a row that exists is *usable*.
    ///
    /// Recorded rather than asserted: `pressed` is the row whose centre was hit by
    /// a pointer sequence, `hitIsSelfOrChild` says whether `elementFromPoint` at
    /// that centre resolved to the row (as opposed to something covering it), and
    /// `after` is what the page showed a couple of seconds later. A row that
    /// exists but is covered passes the layout check and fails this one.
    func pressFirstSessionRow(label: String) {
        guard Self.isEnabled, let webView else { return }
        let script = """
        (function () {
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0
                            && !el.getAttribute('aria-description'));
          if (rows.length === 0) return JSON.stringify({ rows: 0, pressed: null });
          const row = rows[0];
          const rect = row.getBoundingClientRect();
          const x = rect.left + rect.width / 2;
          const y = rect.top + rect.height / 2;
          const hit = document.elementFromPoint(x, y);
          const before = (document.body.innerText || '').length;
          const id = (row.getAttribute('data-row-key') || '').slice('session:'.length);
          const out = {
            rows: rows.length,
            id,
            rect: { left: Math.round(rect.left), top: Math.round(rect.top),
                    width: Math.round(rect.width), height: Math.round(rect.height) },
            inViewport: rect.left >= -1 && rect.top >= -1
              && rect.right <= window.innerWidth + 1 && rect.bottom <= window.innerHeight + 1,
            hitIsSelfOrChild: hit !== null && (hit === row || row.contains(hit)),
            hitTag: hit === null ? null : hit.tagName,
            textBefore: before,
            pressed: false,
          };
          for (const [type] of [['pointerdown', 'touch'], ['pointerup', 'touch'], ['click', 'touch']]) {
            row.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true,
                              pointerType: 'touch', pointerId: 1, isPrimary: true }));
          }
          row.click();
          out.pressed = true;
          return JSON.stringify(out);
        })();
        """
        evaluate(script) { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                var entry: [String: Any] = ["event": "session-row-press", "label": label,
                                            "at": ISO8601DateFormatter().string(from: Date())]
                if let raw = value as? String, let data = raw.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    entry["before"] = parsed
                } else {
                    entry["before"] = NSNull()
                }
                self.sweeps.append(entry)
                self.flush()
                // What the press did. Two seconds is enough for the session to
                // load and the composer to repopulate; it is not a wait for a
                // network round trip, because the session is local.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.sweep(label: label + "+2.5s")
            }
        }
    }

    /// Run the session-row press when the launch arguments ask for it.
    ///
    /// Waits for a row instead of pressing once and giving up: the rows only exist
    /// after a workspace has been chosen, and UIDriver's own sequence does that
    /// several seconds after first paint. Polling is also what makes "there is no
    /// row to press" a recorded fact rather than a race with the UI.
    func pressFirstSessionRowIfConfigured() {
        guard Self.isEnabled,
              UserDefaults.standard.integer(forKey: "DSHPortEPadPressSession") == 1,
              !pressStarted else { return }
        pressStarted = true
        Task { @MainActor in
            _ = try? await waitFor(
                javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                timeout: 300
            )
            var rowCount = 0
            for _ in 0..<60 {
                rowCount = (try? await evaluateAwaitable("document.querySelectorAll('[data-row-key]').length") as? Int) ?? 0
                if rowCount > 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if rowCount == 0 {
                sweeps.append([
                    "event": "session-row-press",
                    "label": "no-row",
                    "note": "no session row was in the DOM after 60 s of polling",
                    "at": ISO8601DateFormatter().string(from: Date()),
                ])
                flush()
                return
            }
            self.pressFirstSessionRow(label: "first-row")
        }
    }

    // MARK: - Keyboard chords

    /// Ask the page what it does with a set of chords, and record the answers.
    ///
    /// THE LIMIT OF THIS MEASUREMENT, STATED UP FRONT. A hardware keyboard cannot
    /// be attached to this simulator from outside: Xcode 27 has no Simulator.app
    /// (removed, not relocated), so there is no Hardware Keyboard menu item, and
    /// no `simctl` verb turns it on. `XCUIDevice`/`typeKey` can, but only from a
    /// UI test, and `xcodebuild` cannot see this task's custom device set.
    ///
    /// So this does NOT measure whether iPadOS intercepts ⌘N before the page sees
    /// it — nothing available here can. What it measures is the half that DSH owns
    /// and that a report can honestly state: given a keydown that reaches the page
    /// with those modifiers, does DSH's shortcut layer act on it, and does it act
    /// on it in this runtime (web) where its own catalogue says some chords are
    /// `unsupported-browser`. The window-level question is left open in the report
    /// and named as open.
    ///
    /// `synthetic: true` marks every record, so a reader is never misled into
    /// thinking a finger or a keyboard produced it.
    func runKeyboardProbeIfConfigured() {
        guard Self.isEnabled,
              UserDefaults.standard.integer(forKey: "DSHPortEPadKeyboard") == 1,
              !keyboardStarted else { return }
        keyboardStarted = true
        Task { @MainActor in
            _ = try? await waitFor(
                javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                timeout: 300
            )
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            // The report's question is about the chords DSH documents in its own
            // reference, so the probe walks that list rather than inventing one.
            // The chords are taken from DSH's own registrations, not guessed. In
            // this runtime the shortcuts layer resolves each binding from its
            // "web:macos" row (platform is macos because navigator.platform is
            // MacIntel in a WKWebView on iPad), and every configurable command's
            // web row uses primary+alt -- so ⌘N alone is NOT the binding here, it is
            // ⌘⌥N. The first version of this probe guessed ⌘+Comma for
            // settings.open and ⌘⌥+Backslash for sidebar.left.toggle; both came back
            // `prevented=false`, which looked like a conflict and was really the
            // wrong chord.
            //
            //   session.new             KeyN        primary+alt   ui-workspace
            //   session.search          KeyK        primary+alt   ui-workspace
            //   workspace.add           KeyO        primary+alt   ui-workspace
            //   sidebar.left.toggle     KeyB        primary+alt   ui-layout
            //   settings.open           Comma       primary+alt   ui-settings-general
            //   shortcuts.open          Slash       primary        ui-shortcuts
            //   pane.fullscreen.toggle  Backslash   primary        ui-sidebar-right
            let chords: [(name: String, code: String, key: String, meta: Bool, alt: Bool, shift: Bool)] = [
                ("session.new", "KeyN", "n", true, true, false),
                ("session.search", "KeyK", "k", true, true, false),
                ("workspace.add", "KeyO", "o", true, true, false),
                ("sidebar.left.toggle", "KeyB", "b", true, true, false),
                ("settings.open", "Comma", ",", true, true, false),
                ("shortcuts.open", "Slash", "/", true, false, false),
                ("pane.fullscreen.toggle", "Backslash", "\\", true, false, false),
                ("send (primary+Enter)", "Enter", "Enter", true, false, false),
                ("plain Escape", "Escape", "Escape", false, false, false),
            ]
            var records: [[String: Any]] = []
            for chord in chords {
                let script = Self.chordScript(code: chord.code, key: chord.key,
                                              meta: chord.meta, alt: chord.alt, shift: chord.shift)
                let value = (try? await evaluateAwaitable(script)) ?? nil
                var record: [String: Any] = [
                    "chord": chord.name,
                    "code": chord.code,
                    "modifiers": [chord.meta ? "meta" : nil, chord.alt ? "alt" : nil,
                                  chord.shift ? "shift" : nil].compactMap { $0 },
                    "synthetic": true,
                ]
                if let raw = value as? String, let data = raw.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    record.merge(parsed) { _, new in new }
                } else {
                    record["raw"] = (value as? String) ?? "nil"
                }
                records.append(record)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            self.sweeps.append([
                "event": "keyboard-chords",
                "at": ISO8601DateFormatter().string(from: Date()),
                "environment": Self.keyboardEnvironment,
                "chords": records,
            ])
            self.flush()
        }
    }

    /// What the page reports about itself, so the chord results can be read in
    /// context. `navigator.platform` decides whether DSH treats "primary" as ⌘ or
    /// Ctrl, and `runtime: web` is what makes some chords `unsupported-browser`.
    /// Recorded per chord by `chordScript`, not here — a value read once at start
    /// would be a stale copy of something the page states for itself.
    private static var keyboardEnvironment: [String: Any] { [:] }

    /// Dispatch one chord and report what the page did with it.
    ///
    /// The event is dispatched on the composer when one is focused or exists,
    /// because that is where DSH's shortcut layer listens for editable-region
    /// chords; otherwise on `document.body`. `defaultPrevented` after dispatch is
    /// the useful signal: DSH's handler calls `preventDefault()` on a chord it
    /// claims, so a `true` here means the page would have acted on it.
    static func chordScript(code: String, key: String, meta: Bool, alt: Bool, shift: Bool) -> String {
        """
        (function () {
          const target = document.querySelector('[contenteditable="true"]') || document.body;
          const init = {
            code: '\(code)', key: '\(key.replacingOccurrences(of: "\\", with: "\\\\"))',
            bubbles: true, cancelable: true,
            metaKey: \(meta ? "true" : "false"), altKey: \(alt ? "true" : "false"),
            shiftKey: \(shift ? "true" : "false"), ctrlKey: false,
          };
          const event = new KeyboardEvent('keydown', init);
          const before = document.body.innerText.length;
          target.dispatchEvent(event);
          return JSON.stringify({
            dispatchedOn: target.tagName,
            defaultPrevented: event.defaultPrevented,
            bodyLengthBefore: before,
            bodyLengthAfter: document.body.innerText.length,
            platform: navigator.platform,
            userAgent: (navigator.userAgent || '').slice(0, 120),
            maxTouchPoints: navigator.maxTouchPoints,
            runtime: document.documentElement.dataset.platform === undefined ? 'web' : 'desktop',
          });
        })();
        """
    }

    // MARK: - Sampling

    /// Record one observation of the app and the page.
    func sweep(label: String) {
        guard Self.isEnabled else { return }
        var entry: [String: Any] = [
            "label": label,
            "at": ISO8601DateFormatter().string(from: Date()),
            "app": appFacts(),
        ]
        guard let webView else {
            entry["dom"] = NSNull()
            sweeps.append(entry)
            flush()
            return
        }
        evaluate(Self.domSnapshotScript()) { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                entry["dom"] = value ?? NSNull()
                entry["webView"] = [
                    "width": Double(webView.bounds.width),
                    "height": Double(webView.bounds.height),
                    "scale": Double(webView.window?.screen.scale ?? 0),
                ]
                self.sweeps.append(entry)
                self.flush()
            }
        }
    }

    /// Drain the page's keystroke log and store it as its own event.
    ///
    /// Kept separate from the layout sweeps because the two are read for
    /// different questions, and because a keystroke log is only meaningful
    /// immediately after somebody typed.
    func drainKeys(label: String) {
        guard Self.isEnabled, let webView else { return }
        evaluate("(function () { return window.__padProbe === undefined ? [] : window.__padProbe.drainKeys(); })();") { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.sweeps.append([
                    "event": "keys",
                    "label": label,
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "keys": value ?? [],
                ])
                self.flush()
                _ = webView
            }
        }
    }

    private func appFacts() -> [String: Any] {
        let app = UIApplication.shared
        let window = app.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let screen = window?.windowScene?.screen ?? UIScreen.main
        let bounds = screen.bounds
        var facts: [String: Any] = [
            "interfaceOrientation": Self.orientationName(window?.windowScene?.interfaceOrientation),
            "deviceOrientation": Self.deviceOrientationName(UIDevice.current.orientation),
            "screenWidth": Double(bounds.width),
            "screenHeight": Double(bounds.height),
            "screenScale": Double(screen.scale),
            // The report cares whether the app could be in a multi-window
            // arrangement at all, and this is the only honest answer: without
            // UIApplicationSupportsMultipleScenes the OS never splits us.
            "supportsMultipleScenes": app.supportsMultipleScenes,
            "connectedScenes": app.connectedScenes.count,
            "sceneSessionCount": app.openSessions.count,
            "sceneActivation": Self.sceneActivationName(app.connectedScenes.first?.activationState),
            "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
        ]
        if let window {
            facts["windowWidth"] = Double(window.bounds.width)
            facts["windowHeight"] = Double(window.bounds.height)
            facts["safeAreaTop"] = Double(window.safeAreaInsets.top)
            facts["safeAreaBottom"] = Double(window.safeAreaInsets.bottom)
            facts["safeAreaLeft"] = Double(window.safeAreaInsets.left)
            facts["safeAreaRight"] = Double(window.safeAreaInsets.right)
        }
        facts["preferredContentSizeCategory"] = UIApplication.shared.preferredContentSizeCategory.rawValue
        return facts
    }

    private static func orientationName(_ orientation: UIInterfaceOrientation?) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }

    private static func deviceOrientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }

    private static func sceneActivationName(_ state: UIScene.ActivationState?) -> String {
        switch state {
        case .some(.foregroundActive): return "foregroundActive"
        case .some(.foregroundInactive): return "foregroundInactive"
        case .some(.background): return "background"
        case .some(.unattached): return "unattached"
        default: return "unknown"
        }
    }

    /// What the page looks like, in the terms the report asks about.
    ///
    /// `overflowing` and `unclickable` are the two failure modes a narrower
    /// window produces: an element wider than its container (text clipped,
    /// scrolled sideways) and an element whose centre is covered by something
    /// else (a tap lands on the wrong thing). Both are measured by asking the
    /// DOM, not by looking at a screenshot.
    static func domSnapshotScript() -> String {
        """
        (function () {
          const frame = document.querySelector('[data-sidebar-collapsed], [class*="_frame"]');
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0);
          const composer = document.querySelector('[contenteditable="true"]');
          const out = {
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            dpr: window.devicePixelRatio,
            resizes: window.__padProbeResizes || 0,
            docScrollWidth: document.documentElement.scrollWidth,
            bodyScrollWidth: document.body ? document.body.scrollWidth : 0,
            horizontalOverflow: (document.documentElement.scrollWidth > window.innerWidth + 1),
            sidebarCollapsedAttr: frame === null ? null
              : (frame.hasAttribute('data-sidebar-collapsed') ? true : false),
            gridTemplateColumns: frame === null ? null : (getComputedStyle(frame).gridTemplateColumns || ''),
            sidebarWidth: null,
            sessionRowCount: rows.length,
            sessionRowTitles: rows.slice(0, 12).map((el) => (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 60)),
            composerPresent: composer !== null,
            textLength: (document.body.innerText || '').length,
          };
          const sidebarCol = document.querySelector('[class*="_sidebarCol"]');
          if (sidebarCol !== null) {
            const rect = sidebarCol.getBoundingClientRect();
            out.sidebarWidth = Math.round(rect.width);
          }
          // Elements that are PARTLY outside the viewport, or positioned outside
          // it. A short list, because the useful thing is "does anything spill",
          // not a dump.
          //
          // "Exactly the same condition" matters: DSH keeps its right-hand panes
          // mounted and slides them off to the right, so `left >= innerWidth` is
          // normal and does not mean anything spilled. Measured the wrong way
          // first -- counting everything whose `right` passed the viewport edge
          // reported eight "spills" in a layout whose docScrollWidth equals
          // innerWidth exactly, i.e. a layout that does not scroll sideways at
          // all. What actually matters is an element that is partly ON screen and
          // partly off, because that is the one whose text gets clipped or whose
          // tap target is half unreachable.
          const spill = [];
          const clipped = [];
          for (const el of document.querySelectorAll('body *')) {
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) continue;
            const partlyHorizontal = rect.left < window.innerWidth - 1 && rect.right > window.innerWidth + 2;
            const partlyVertical = rect.top < window.innerHeight - 1 && rect.bottom > window.innerHeight + 2;
            if (partlyHorizontal || partlyVertical) {
              if (clipped.length < 8) {
                clipped.push({
                  tag: el.tagName,
                  cls: String(el.className || '').slice(0, 60),
                  left: Math.round(rect.left),
                  top: Math.round(rect.top),
                  right: Math.round(rect.right),
                  bottom: Math.round(rect.bottom),
                  vertical: partlyVertical,
                });
              }
              continue;
            }
            // Fully outside: recorded as a count only, because off-screen panes
            // are how this UI parks things it is not showing.
            if (rect.right > window.innerWidth + 2 || rect.left < -2) {
              if (spill.length < 8) {
                spill.push({
                  tag: el.tagName,
                  cls: String(el.className || '').slice(0, 60),
                  left: Math.round(rect.left),
                  right: Math.round(rect.right),
                  width: Math.round(rect.width),
                });
              }
            }
          }
          out.spill = spill;
          out.clipped = clipped;
          // Everything the page has received since the last sweep. Draining here
          // rather than through a separate call means a keystroke cannot be lost
          // between a layout sweep and a keystroke sweep: both read the same log
          // at the same instant, and the entries carry the label that says which
          // moment they belong to.
          out.keys = (window.__padProbe === undefined) ? [] : window.__padProbe.drainKeys();
          // Is the composer's send control actually hittable at its own centre?
          const send = document.querySelector('button[aria-label*="发送"], button[aria-label*="Send"]')
            || Array.from(document.querySelectorAll('button')).find((b) => {
                 const r = b.getBoundingClientRect();
                 return r.width > 20 && r.width < 60 && r.height > 20 && r.height < 60;
               });
          if (send !== undefined && send !== null) {
            const rect = send.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            const hit = document.elementFromPoint(x, y);
            out.sendButton = {
              found: true,
              label: send.getAttribute('aria-label') || '',
              disabled: !!send.disabled,
              rect: { left: Math.round(rect.left), top: Math.round(rect.top),
                      width: Math.round(rect.width), height: Math.round(rect.height) },
              inViewport: rect.left >= -1 && rect.top >= -1
                && rect.right <= window.innerWidth + 1 && rect.bottom <= window.innerHeight + 1,
              hitIsSelfOrChild: hit !== null && (hit === send || send.contains(hit)),
              hitTag: hit === null ? null : hit.tagName,
            };
          } else {
            out.sendButton = { found: false };
          }
          return out;
        })();
        """
    }

    // MARK: - Plumbing

    private func evaluate(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let webView else { completion(nil); return }
        webView.evaluateJavaScript(script) { value, _ in
            completion(value)
        }
    }

    private func flush() {
        let payload: [String: Any] = [
            "probe": "padprobe",
            "enabled": true,
            "device": [
                "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
                "name": UIDevice.current.name,
                "systemVersion": UIDevice.current.systemVersion,
            ],
            "sweeps": sweeps,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    /// Load and store one sweep, for the UI test to trigger at a named moment.
    var reportPath: String { reportURL.path }
}

// MARK: - Split View stand-in

/// Narrow the content to a fraction of the window and pin it to the leading
/// edge, the way a Split View pane looks.
///
/// This is the approximation PadProbe's comment describes: DSH's layout store
/// reads the frame element's measured width, so a narrower web view produces the
/// same arrangement decision a real Split View pane would. What it does not
/// reproduce is iPadOS actually resizing the scene — the keyboard insets, the
/// safe-area values and the multitasking affordances all stay full-screen.
private struct PadLayoutFraction: ViewModifier {
    let fraction: Double?

    func body(content: Content) -> some View {
        if let fraction {
            GeometryReader { proxy in
                content
                    .frame(width: (proxy.size.width * fraction).rounded(.down),
                           height: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(.black)
        } else {
            content
        }
    }
}

extension View {
    /// No-op unless PadProbe is enabled and a fraction was supplied on the
    /// command line, so a normal launch lays out exactly as before.
    func padLayoutFraction(_ fraction: Double?) -> some View {
        modifier(PadLayoutFraction(fraction: fraction))
    }
}
