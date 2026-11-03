//
//  UIDriver.swift
//  DSHPortC
//
//  An in-app driver for the end-to-end test, enabled only by a launch argument.
//
//  WHY THIS EXISTS
//  ---------------
//  XCUITest's accessibility snapshot of DSH's React tree is large and unstable:
//  enumerating its descendants fails intermittently with "No matches found for
//  Element at index N". That makes it a poor instrument for asserting that a
//  streamed reply grows incrementally — the very timing the test is about.
//
//  This driver evaluates JavaScript inside the app's own WKWebView. That is the
//  same context DSH's front-end runs in, so what it observes is what a person
//  looking at the screen would see, without depending on the accessibility tree.
//
//  GATING
//  ------
//  Nothing here runs unless the app is launched with `-DSHPortCTestDrive 1`.
//  A normal launch never reaches this code, so shipping it costs nothing at
//  runtime and it cannot be triggered by the UI itself.
//

import Foundation
import WebKit

@MainActor
final class UIDriver {
    static let shared = UIDriver()

    /// True when the process was launched by the test harness.
    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortCTestDrive") == 1
    }

    private var webView: WKWebView?
    private var samples: [[String: Any]] = []
    /// Events recorded before a scripted run starts, kept apart because
    /// `runScriptedPrompt` resets `samples` to zero for its own sampling.
    ///
    /// This exists because of a real measurement mistake: the session-opening
    /// steps ran first and were correct, then the prompt's `samples.removeAll()`
    /// erased them, so the evidence file looked as though those steps never ran.
    /// Reporting "did not happen" for work that did happen is the same class of
    /// error as reporting success for work that did not.
    private var prelude: [[String: Any]] = []
    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DSHPortC-uidrive.json")
    }()

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        // Record the launch-argument domain, so "the flag never arrived" and "the
        // flag arrived and the code ignored it" are distinguishable from the
        // evidence file instead of by guessing.
        write(["event": "registered",
               "testDrive": UserDefaults.standard.integer(forKey: "DSHPortCTestDrive"),
               "openFirstSession": UserDefaults.standard.integer(forKey: "DSHPortCTestOpenFirstSession"),
               "clocks": ProcessInfo.processInfo.environment["DSHPORT_UITEST_CLOCKS"] ?? "(absent)"])
    }

    /// Start the scripted run named by the launch environment, if any.
    ///
    /// The test harness passes `DSHPORT_UITEST_PROMPT` and one of the keywords
    /// the mock model server keys on. Keeping the choice here rather than in the
    /// Swift source means one build can drive any of the three scenarios.
    func runScriptedPromptIfConfigured() {
        guard Self.isEnabled else { return }
        // The prompt can arrive two ways: as a launch argument
        // (`-DSHPortCTestPrompt <text>`, which lands in the argument domain and is
        // per-launch) or as `SIMCTL_CHILD_DSHPORT_UITEST_PROMPT`.
        //
        // The argument form exists because the environment form is unreliable: the
        // simulator keeps the FIRST `SIMCTL_CHILD_*` values it saw until the whole
        // device shuts down (REPORT-5 records this from the ancestor-EPERM test).
        // Measured here: a launch that passed the variable arrived with no prompt
        // at all and the driver wrote `idle / no prompt configured`, while the
        // launch argument for a different flag did arrive.
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let prompt = environment["DSHPORT_UITEST_PROMPT"]
            ?? defaults.string(forKey: "DSHPortCTestPrompt")
        guard let prompt, !prompt.isEmpty else {
            write(["event": "idle", "reason": "no prompt configured",
                   "sawEnvKey": environment["DSHPORT_UITEST_PROMPT"] != nil,
                   "sawArgKey": defaults.string(forKey: "DSHPortCTestPrompt") != nil])
            return
        }
        let keyword = environment["DSHPORT_UITEST_KEYWORD"]
            ?? UserDefaults.standard.string(forKey: "DSHPortCTestKeyword")
            ?? "STREAMTEST-COMPLETE"
        // Attachment names are opt-in: their presence is what turns this into the
        // attachment run. Comma-separated so one launch can send a batch, which is
        // how the acceptance proves several formats in one prompt.
        let attachments = (environment["DSHPORT_UITEST_ATTACHMENTS"]
            ?? UserDefaults.standard.string(forKey: "DSHPortCTestAttachments"))
            .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ?? []
        // Step 6: continue an EXISTING session instead of starting a new one, so
        // "the old session still works after a container change" is what the run
        // proves. Awaited, not fired alongside: the composer belongs to whichever
        // session is selected, and a prompt sent while the switch is still in
        // flight would land in the wrong one (or in none).
        let ready = Task { @MainActor in await self.openFirstSessionIfConfigured() }
        Task { @MainActor in
            await ready.value
            if attachments.isEmpty {
                self.runScriptedPrompt(prompt, keyword: keyword)
            } else {
                self.runScriptedAttachmentPrompt(prompt, keyword: keyword, attachments: attachments)
            }
        }
    }

    /// Read the clocks the interface actually rendered, plus the page's own idea
    /// of time.
    ///
    /// Step 6 needs this: the requirement is that a message's displayed time
    /// matches the device's local time, and the only witness to "displayed" is
    /// the DOM. Reading the same instants through the page's own `Date` and
    /// `Intl` alongside the rendered text is what separates "the clock is right"
    /// from "the clock is right by luck": both must agree, and both must agree
    /// with the expected local wall clock.
    ///
    /// @param expected array of expectations, `{ iso, wall }`, produced by the caller
    /// @returns JavaScript source whose result is a JSON string.
    static func clockProbeScript(_ expectedJSON: String) -> String {
        """
        (function () {
          const scan = (root) => {
            const out = [];
            for (const el of root.querySelectorAll('[data-clock]')) {
              const text = (el.textContent || '').trim();
              if (text.length > 0) out.push({ where: el.getAttribute('data-clock'), text });
            }
            return out;
          };
          // Every text node that looks like a wall clock, wherever it sits. The
          // chat row's clock is a `data-clock` span, but the timeline's is a
          // tooltip and the workspace hover card builds its own string; scanning
          // the body catches all of them instead of only the one shape that was
          // known when this was written.
          const times = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const clockLike = /(^|\\s)([01]?\\d|2[0-3]):[0-5]\\d(\\s|$)/;
          while (walker.nextNode()) {
            const value = (walker.currentNode.nodeValue || '').trim();
            if (value.length > 0 && value.length <= 40 && clockLike.test(value)) times.push(value);
          }
          const pageNow = new Date();
          const pad = (n) => String(n).padStart(2, '0');
          const localWall = pageNow.getFullYear() + '-' + pad(pageNow.getMonth() + 1) + '-' + pad(pageNow.getDate())
            + ' ' + pad(pageNow.getHours()) + ':' + pad(pageNow.getMinutes());
          // The formatter DSH's time-context builds, evaluated in the page, so the
          // model-visible stamp and the rendered clock are compared under the same
          // rules.
          const fmt = new Intl.DateTimeFormat('en-US', {
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', second: '2-digit',
            hourCycle: 'h23', timeZoneName: 'longOffset',
          });
          const zone = fmt.resolvedOptions().timeZone;
          const stamp = (ms) => {
            const p = Object.fromEntries(fmt.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
            return p.year + '-' + p.month + '-' + p.day + 'T' + p.hour + ':' + p.minute + ':' + p.second
              + (p.timeZoneName || '').replace(/^GMT$/, 'GMT+00:00').slice(3) + '[' + zone + ']';
          };
          const expected = \(expectedJSON);
          const cases = expected.map((e) => ({ iso: e.iso, expectedWall: e.wall, got: stamp(Date.parse(e.iso)) }));
          return JSON.stringify({
            clockSpans: scan(document),
            clockTexts: times,
            page: {
              zone,
              offsetMinutes: pageNow.getTimezoneOffset(),
              localWall,
              timezoneName: pageNow.toLocaleTimeString(undefined, { timeZoneName: 'short' }).split(' ').pop(),
              nowStamp: stamp(Date.now()),
            },
            cases,
          });
        })();
        """
    }

    /// Open the first session in the sidebar and continue it.
    ///
    /// Step 6's acceptance needs this: after a container change, the requirement
    /// is not merely that the log survived on disk but that the session is IN THE
    /// LIST and a further turn runs inside it. That means pressing the real row,
    /// not creating a new session — a new session would pass even if the old one
    /// were unreadable.
    ///
    /// The sidebar is a drawer on this device, so it has to be opened first. Row
    /// identity is `[data-row-key="session:<id>"]`, which the workspace browser
    /// sets on every row (dsh-client-ui-workspace client.js:2275).
    func openFirstSessionIfConfigured() async {
        guard Self.isEnabled, let webView else { return }
        // A launch ARGUMENT, not a SIMCTL_CHILD_* variable. The simulator keeps
        // the first `SIMCTL_CHILD_*` values it saw until the whole device is shut
        // down (REPORT-5 records this trap from the ancestor-EPERM test), so a
        // variable introduced on a later launch of the same boot never arrives —
        // measured here: the driver's own events were absent entirely while the
        // prompt still worked. Launch arguments are per-launch and carry no such
        // memory (this is how `DSHPortCTestDrive` already works).
        guard UserDefaults.standard.integer(forKey: "DSHPortCTestOpenFirstSession") == 1 else { return }
        await { @MainActor in
            _ = try? await waitFor(
                javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                timeout: 300, label: "plugins loaded"
            )
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // The narrow layout is not a bug to work around from inside the page.
            //
            // Measured: this device lays out at 402 px, below DSH's 1024 px
            // `SIDEBAR_AUTO_COLLAPSE` threshold, so the sidebar is a 56 px rail and
            // the session list is not in the DOM at all. Resizing the WKWebView from
            // here does not help — SwiftUI re-applies the constraint, and the frame
            // kept measuring 402 px. The simulator can present a larger screen
            // instead, which is what `scripts/sim-container-sessions.py` asks for;
            // when the harness has done that, the rows are simply there.
            //
            // Nothing here forces the layout, deliberately: a real user on this
            // phone gets the rail, and that is the correct design for a phone.

            // The workspace has to be chosen first. Until it is, DSH renders the
            // hero screen and the sidebar has no session list at all — measured
            // once: `sidebar_open -> pressed:打开侧边栏` followed by
            // `session_rows_after_open -> {"rows":[],"sidebarVisible":false}`, with
            // the body still showing "探索未至之境 / 默认工作区 / 添加工作区…".
            // Choosing it here rather than assuming the prompt sequence already did
            // is what makes this usable on a cold launch.
            var workspaceOpened: Any?
            for attempt in 1...15 {
                workspaceOpened = try? await evaluate(Self.workspaceScript(phase: "open"))
                if ((workspaceOpened as? String) ?? "nil") != "no-workspace-trigger" { break }
                writePrelude(["event": "session_workspace_wait", "attempt": attempt,
                       "result": (workspaceOpened as? String) ?? "nil"])
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            writePrelude(["event": "session_workspace_open", "result": (workspaceOpened as? String) ?? "nil"])
            if (workspaceOpened as? String) == "trigger-pressed" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let row = try? await evaluate(Self.workspaceScript(phase: "row", label: "默认工作区"))
                writePrelude(["event": "session_workspace_pick", "result": (row as? String) ?? "nil"])
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            // List what is there first, so a failure names the state rather than
            // reporting only that a click missed.
            if let dump = try? await evaluate(Self.sessionRowsScript()) {
                writePrelude(["event": "session_rows", "dump": dump])
            }

            // Press the toggle until a session row actually appears. One press is
            // not reliably enough: the first lands while React is still finishing
            // the workspace switch, the drawer opens and closes, and only a later
            // press leaves it open. Waiting for the ROW rather than for a fixed
            // delay is what makes that self-correcting, and recording the count per
            // attempt is what makes a failure diagnosable.
            for attempt in 1...12 {
                let opened = try? await evaluate(Self.openSidebarScript())
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let count = (try? await evaluate(Self.sessionRowCountScript()) as? Int) ?? -1
                // Also record whether the frame still reports itself as collapsed.
                // The row count alone cannot tell "the drawer never opened" from
                // "the drawer opened onto an empty list".
                let collapsed = (try? await evaluate(Self.sidebarStateScript()) as? String) ?? "?"
                writePrelude(["event": "sidebar_open", "attempt": attempt,
                              "result": (opened as? String) ?? "nil", "rows": count, "frame": collapsed])
                if count > 0 { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let dump = try? await evaluate(Self.sessionRowsScript()) {
                writePrelude(["event": "session_rows_after_open", "dump": dump])
            }
            let pressed = try? await evaluate(Self.pressFirstSessionScript())
            writePrelude(["event": "session_pressed", "result": (pressed as? String) ?? "nil"])
            // Whether the session is in the list DSH renders from. A separate
            // question from "was a row clicked", and answered without pretending
            // the click succeeded (see probeSessionInListScript).
            if let wanted = UserDefaults.standard.string(forKey: "DSHPortCTestSessionId"),
               !wanted.isEmpty,
               let presence = try? await evaluate(Self.probeSessionInListScript(wanted)) {
                writePrelude(["event": "session_in_list", "result": presence])
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let text = try? await evaluate("(document.body.innerText || '').slice(0, 400)") as? String {
                writePrelude(["event": "after_press_body", "text": text])
            }
        }()
    }

    /// What the frame reports about the sidebar, plus the viewport it decided with.
    ///
    /// The layout store keeps `narrowExpanded` (below 1024 px) or `sidebar` (above)
    /// and exposes the decision as `data-sidebar-collapsed` on the frame element
    /// (dsh-client-ui-layout client.js:238, 323). Reading that attribute is how this
    /// distinguishes a drawer that never opened from one opened onto an empty list.
    static func sidebarStateScript() -> String {
        """
        (function () {
          const frame = document.querySelector('[data-sidebar-collapsed], .dsh-frame, #root > div > div');
          const collapsed = frame === null ? 'no-frame' : (frame.hasAttribute('data-sidebar-collapsed') ? 'collapsed' : 'expanded');
          const grid = frame === null ? '' : (getComputedStyle(frame).gridTemplateColumns || '');
          return JSON.stringify({ collapsed, grid, width: window.innerWidth, height: window.innerHeight });
        })();
        """
    }

    /// How many session rows the sidebar currently renders.
    static func sessionRowCountScript() -> String {
        """
        (function () {
          return Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0).length;
        })();
        """
    }

    /// Every session row the sidebar currently renders: its id, its title, and
    /// whether it is the selected one.
    static func sessionRowsScript() -> String {
        """
        (function () {
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0)
            .map((el) => ({
              key: el.getAttribute('data-row-key'),
              id: (el.getAttribute('data-row-key') || '').slice('session:'.length),
              text: (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 80),
              selected: el.getAttribute('aria-selected') === 'true',
              archived: (el.getAttribute('aria-description') || '').length > 0,
            }));
          return JSON.stringify({
            rows,
            sidebarVisible: !!document.querySelector('[data-row-key]'),
            bodyStart: (document.body.innerText || '').slice(0, 200),
          });
        })();
        """
    }

    /// Open the sidebar drawer if it is closed.
    static func openSidebarScript() -> String {
        """
        (function () {
          if (document.querySelector('[data-row-key]') !== null) return 'already-open';
          const wanted = ['打开侧边栏', 'Open sidebar'];
          const buttons = Array.from(document.querySelectorAll('button,[role="button"]'));
          for (const button of buttons) {
            const label = button.getAttribute('aria-label') || '';
            const text = (button.innerText || '').trim();
            if (wanted.some((w) => label.indexOf(w) >= 0 || text === w)) {
              const seq = [['pointerdown', 'touch'], ['pointerup', 'touch'], ['click', 'touch']];
              for (const [type] of seq) {
                button.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));
              }
              button.click();
              return 'pressed:' + (label || text);
            }
          }
          return 'no-sidebar-button';
        })();
        """
    }

    /// Report whether one session is in the list DSH renders from.
    ///
    /// WHY NOT A CLICK. On this device DSH lays out narrow (402 px, below its
    /// 1024 px `SIDEBAR_AUTO_COLLAPSE` threshold), so the sidebar is a 56 px rail
    /// and the session rows are not in the document at all: twelve presses of the
    /// rail toggle left `data-sidebar-collapsed` in place, and enlarging the
    /// WKWebView from here does not survive SwiftUI's layout pass. Reaching the
    /// rows would mean calling into the client's module system, which exposes no
    /// module-getter (`window.__ModuleLoader__` starts as a queue and is replaced
    /// by a system with only `load`), and inventing a path into it is not something
    /// a verification step should do.
    ///
    /// So what this records, honestly: whether the session id appears anywhere the
    /// page holds state about it (`localStorage` per plugin, and the rendered text).
    /// The report says plainly that this is weaker than a click and that the
    /// end-to-end confirmation is a person opening the app on a device.
    ///
    /// @param sessionId the session the acceptance has been following
    static func probeSessionInListScript(_ sessionId: String) -> String {
        let escaped = sessionId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          const wanted = '\(escaped)';
          const out = { sessionId: wanted, renderedRow: false, inStorage: [], inBody: false,
                        width: window.innerWidth, frame: null };
          for (const el of document.querySelectorAll('[data-row-key]')) {
            if ((el.getAttribute('data-row-key') || '') === 'session:' + wanted) out.renderedRow = true;
          }
          try {
            for (let i = 0; i < localStorage.length; i += 1) {
              const key = localStorage.key(i);
              const value = String(localStorage.getItem(key) || '');
              if (value.indexOf(wanted) >= 0) out.inStorage.push(key.slice(0, 80));
            }
          } catch (e) { out.storageError = String(e); }
          out.inBody = (document.body.innerText || '').indexOf(wanted) >= 0;
          const frame = document.querySelector('[data-sidebar-collapsed]');
          if (frame !== null) {
            out.frame = { collapsed: frame.hasAttribute('data-sidebar-collapsed'),
                          grid: getComputedStyle(frame).gridTemplateColumns || '' };
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// Press the first session row, the way a finger would.
    static func pressFirstSessionScript() -> String {
        """
        (function () {
          const rows = Array.from(document.querySelectorAll('[data-row-key]'))
            .filter((el) => (el.getAttribute('data-row-key') || '').indexOf('session:') === 0 && !el.getAttribute('aria-description'));
          if (rows.length === 0) return 'no-session-row';
          const row = rows[0];
          const id = (row.getAttribute('data-row-key') || '').slice('session:'.length);
          row.scrollIntoView({ block: 'nearest' });
          row.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));
          row.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));
          row.click();
          return 'pressed:' + id;
        })();
        """
    }

    /// Run a sequence: wait for the composer, type a prompt, send it, then sample
    /// the rendered text length until it stops growing.
    func runScriptedPrompt(_ prompt: String, keyword: String, timeout: TimeInterval = 120) {
        guard Self.isEnabled, let webView else { return }
        samples.removeAll()
        write(["event": "start", "prompt": prompt, "keyword": keyword])

        Task { @MainActor in
            do {
                // 1a. Wait for the front-end to finish loading its plugin
                // bundles. The page reports "Loading plugins…" first and only
                // then builds the real UI; sampling before that sees an empty
                // document and no composer.
                _ = try? await waitFor(
                    javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                    timeout: 300,
                    label: "plugins loaded"
                )
                try await Task.sleep(nanoseconds: 2_000_000_000)

                // 1b. Wait for the page to be non-empty before anything else.
                //
                // `didFinish` firing does NOT mean the document has content: the
                // shell loads, then the module graph boots, then React renders.
                // Measured once: the driver ran its whole sequence against a
                // blank document (`bodyText: ''`, zero buttons), reported
                // 'no-workspace-trigger' fifteen times, and finally timed out
                // waiting for a composer that was never going to appear — the
                // page simply had not rendered yet.
                var sawContent = false
                for attempt in 1...60 {
                    if let length = try? await evaluate("document.body.innerText.length") as? Int, length > 40 {
                        sawContent = true
                        write(["event": "page_content", "attempt": attempt, "length": length])
                        break
                    }
                    if attempt % 10 == 0 {
                        write(["event": "page_wait", "attempt": attempt])
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !sawContent {
                    write(["event": "page_never_rendered", "note": "document.body.innerText stayed empty" ])
                }

                // 1c. Dump the interactive surface, so a failure is diagnosable
                // from the report instead of from a screenshot.
                if let dump = try? await evaluate(Self.dumpScript()) {
                    write(["event": "dom_dump", "dump": dump])
                }

                // 1c. Select a workspace when the UI is asking for one. DSH
                // registers a default workspace on first run but still requires
                // the user to pick it before the composer becomes usable.
                //
                // The picker is a React popup: it opens on pointerdown on the
                // trigger and its rows commit on pointerup. Two separate
                // evaluations therefore cannot do it — the release has to follow
                // the press inside the same user-activation window — so the whole
                // sequence runs in one script and reports where it got to.
                // Wait for the hero's workspace row before pressing it. It is
                // rendered by the React tree after the plugin bundles load, and
                // 2 s is not always enough on a cold first paint: measured once,
                // the trigger was still absent and the whole run then timed out
                // waiting for a composer it could never reach.
                var opened: Any? = nil
                for attempt in 1...15 {
                    opened = try? await evaluate(Self.workspaceScript(phase: "open"))
                    let outcome = (opened as? String) ?? "nil"
                    if outcome != "no-workspace-trigger" { break }
                    write(["event": "workspace_wait", "attempt": attempt, "result": outcome])
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                write(["event": "workspace_open", "result": (opened as? String) ?? "nil"])
                // The popup's rows are a React render away; a real finger takes
                // longer than this between the press and the choice anyway.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                var pickedResult = "not-attempted"
                if (opened as? String) == "trigger-pressed" {
                    let row = try? await evaluate(Self.workspaceScript(phase: "row", label: "默认工作区"))
                    pickedResult = (row as? String) ?? "nil"
                    write(["event": "workspace_pick", "result": pickedResult])
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)

                if let events = try? await evaluate(Self.drainDiagnosticsScript()) {
                    write(["event": "page_diagnostics", "entries": events ?? []])
                }
                if let diag = try? await evaluate(Self.diagnosticScript()) {
                    write(["event": "diagnostics", "dump": diag])
                }
                if let dump = try? await evaluate(Self.dumpScript()) {
                    write(["event": "dom_dump_after_pick", "dump": dump])
                }

                // 1. Wait until the composer exists and a workspace is selected.
                let ready = try await waitFor(
                    javaScript: "document.querySelectorAll('textarea,[contenteditable=\"true\"]').length > 0",
                    timeout: 180,
                    label: "composer"
                )
                write(["event": "composer", "found": ready])

                // 2. Type into the composer and submit.
                //
                // The web view has to be first responder first. `document
                // .execCommand` and the `beforeinput` path it drives are refused
                // outright when the WKWebView itself is not the focused editable
                // host, and the refusal is silent: execCommand answers false (or
                // true having done nothing) and the editor stays empty. A real
                // finger focuses the view as a side effect of the tap, which is
                // why this only shows up on the programmatic path.
                _ = webView.becomeFirstResponder()
                try await Task.sleep(nanoseconds: 400_000_000)
                let typed = try await evaluate(Self.typeAndSendScript(prompt))
                write(["event": "typed", "result": typed])
                // Lexical commits inside a React transition: the DOM text and
                // the send button's enabled state land a frame or two after the
                // insertion returns. Reading them in the same evaluation would
                // report a stale empty editor.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let sent = try? await evaluate(Self.sendScript())
                write(["event": "sent", "result": (sent as? String) ?? "nil"])
                if ((sent as? String) ?? "").hasPrefix("send-disabled") {
                    // One retry: the transition can still be in flight under load
                    // (the whole app is one jitless process).
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let retried = try? await evaluate(Self.sendScript())
                    write(["event": "sent_retry", "result": (retried as? String) ?? "nil"])
                }

                // 2b. Answer the approval dialog when one appears.
                //
                // This exists because the acceptance criterion is not just "the
                // dialog renders" — it is "a command that needs approval gets
                // asked, and after approval it runs". Left unanswered, the turn
                // blocks forever, which is correct behaviour and also
                // indistinguishable from a hang.
                //
                // STEP 16's OPT-OUT. One acceptance case is about the WAITING state:
                // "a tool is waiting for approval" has to raise a notification, and the
                // notification has to be withdrawn once the user answers it in the app.
                // This loop would answer the dialog before that case could observe either,
                // so a launch that says `-DSHPortEHoldApproval 1` keeps the dialog up. A
                // normal launch, and every earlier step's run, never passes the flag, so
                // the behaviour those cases measure is unchanged.
                let holdApproval = UserDefaults.standard.integer(forKey: "DSHPortEHoldApproval") == 1
                if holdApproval {
                    write(["event": "approval_watch", "result": "skipped-by-DSHPortEHoldApproval"])
                }
                for attempt in 1..<(holdApproval ? 1 : 13) {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let clicked = try? await evaluate(Self.approveScript())
                    let outcome = (clicked as? String) ?? "nil"
                    write(["event": "approval_watch", "attempt": attempt, "result": outcome])
                    if outcome.hasPrefix("clicked-allow") || outcome == "no-dialog" { break }
                }

                // 3. Sample rendered text length, recording each growth step.
                let deadline = Date().addingTimeInterval(timeout)
                var last = -1
                var growth = 0
                while Date() < deadline {
                    let probe = try await evaluate(Self.probeScript(keyword))
                    if let dict = probe as? [String: Any],
                       let length = dict["length"] as? Int {
                        let done = dict["done"] as? Bool ?? false
                        if length > last + 1 {
                            growth += 1
                            last = length
                            samples.append([
                                "t": Date().timeIntervalSince1970,
                                "length": length,
                                "growth": growth,
                            ])
                        }
                        if done {
                            write(["event": "reply_complete", "length": length, "growth": growth])
                            break
                        }
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                write([
                    "event": "finish",
                    "growth": growth,
                    "samples": samples,
                    "finalText": (try? await evaluate("document.body.innerText.slice(-1500)")) ?? "",
                ])
                await recordClocksIfConfigured()
            } catch {
                write(["event": "error", "message": "\(error)"])
            }
        }
    }

    /// Record what the interface displays as the current time, when the harness
    /// asked for it (DSHPORT_UITEST_CLOCKS=1).
    ///
    /// Kept separate from the turn script so the same probe can be run against a
    /// finished conversation without driving a new prompt, and so a failure here
    /// cannot be mistaken for a failed turn.
    func recordClocksIfConfigured() async {
        // A launch argument for the same reason as the other test flags: the
        // simulator keeps the first `SIMCTL_CHILD_*` values it saw until the whole
        // device shuts down, and a variable introduced on a later launch of the
        // same boot never arrives.
        guard Self.isEnabled,
              UserDefaults.standard.integer(forKey: "DSHPortCTestClocks") == 1 else { return }
        // The instants the report compares: four on each side of both 2026 Sydney
        // transitions, plus one plain summer and one plain winter date. Written
        // out here rather than derived, so the expectation is a statement rather
        // than a reimplementation of the code under test.
        let expected: [[String: String]] = [
            ["iso": "2026-01-15T00:00:00Z", "wall": "2026-01-15T11:00:00+11:00"],
            ["iso": "2026-04-04T15:59:59Z", "wall": "2026-04-05T02:59:59+11:00"],
            ["iso": "2026-04-04T16:00:00Z", "wall": "2026-04-05T02:00:00+10:00"],
            ["iso": "2026-07-15T00:00:00Z", "wall": "2026-07-15T10:00:00+10:00"],
            ["iso": "2026-10-03T15:59:59Z", "wall": "2026-10-04T01:59:59+10:00"],
            ["iso": "2026-10-03T16:00:00Z", "wall": "2026-10-04T03:00:00+11:00"],
            ["iso": "2026-12-31T13:00:00Z", "wall": "2027-01-01T00:00:00+11:00"],
            ["iso": "2027-07-01T00:00:00Z", "wall": "2027-07-01T10:00:00+10:00"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: expected),
              let json = String(data: data, encoding: .utf8) else { return }
        let raw = try? await evaluate(Self.clockProbeScript(json))
        var record: [String: Any] = ["event": "clocks", "expected": expected]
        if let text = raw as? String, let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            record["observed"] = parsed
        } else {
            record["observed"] = NSNull()
            record["note"] = "the page returned no clock snapshot"
        }
        record["hostWall"] = ISO8601DateFormatter().string(from: Date())
        record["hostOffsetMinutes"] = TimeZone.current.secondsFromGMT() / 60
        record["hostZone"] = TimeZone.current.identifier
        write(record)
    }

    /// Run the attachment variant: wait for the composer, attach the named files
    /// through the page's own file input, then type and send.
    ///
    /// WHY THE PAGE'S FILE INPUT AND NOT A CUSTOM DROP: the composer accepts files
    /// through `onPickFiles` (the hidden `<input type="file">`'s change event) and
    /// through document-level drop handlers. Both funnel into the same
    /// `intakeFiles` → `addFiles` path, so either would exercise the real
    /// admission route. The input is used because a `DataTransfer` can be
    /// populated with real `File` objects in this WebKit, which makes the change
    /// event carry exactly what a finger-picked file carries.
    ///
    /// The bytes are handed over in bounded chunks rather than one huge script
    /// literal: a 15 MB JPEG becomes ~20 MB of base64, and a single
    /// `evaluateJavaScript` string of that size is both slow to parse and prone
    /// to being truncated. Each chunk appends to a page-side buffer, and the last
    /// call assembles the `File` and dispatches the event.
    func runScriptedAttachmentPrompt(_ prompt: String, keyword: String, attachments: [String], timeout: TimeInterval = 180) {
        guard Self.isEnabled, let webView else { return }
        samples.removeAll()
        write(["event": "start", "prompt": prompt, "keyword": keyword, "attachments": attachments])

        Task { @MainActor in
            do {
                _ = try? await waitFor(
                    javaScript: "(document.body.innerText || '').indexOf('Loading plugins') < 0",
                    timeout: 300,
                    label: "plugins loaded"
                )
                try await Task.sleep(nanoseconds: 2_000_000_000)
                for attempt in 1...60 {
                    if let length = try? await evaluate("document.body.innerText.length") as? Int, length > 40 {
                        write(["event": "page_content", "attempt": attempt, "length": length])
                        break
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                // Same workspace selection the text runs need: DSH registers a
                // default workspace but still requires a pick before the composer
                // becomes usable.
                var opened: Any? = nil
                for attempt in 1...15 {
                    opened = try? await evaluate(Self.workspaceScript(phase: "open"))
                    if ((opened as? String) ?? "nil") != "no-workspace-trigger" { break }
                    write(["event": "workspace_wait", "attempt": attempt, "result": (opened as? String) ?? "nil"])
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                write(["event": "workspace_open", "result": (opened as? String) ?? "nil"])
                try await Task.sleep(nanoseconds: 1_500_000_000)
                if (opened as? String) == "trigger-pressed" {
                    let row = try? await evaluate(Self.workspaceScript(phase: "row", label: "默认工作区"))
                    write(["event": "workspace_pick", "result": (row as? String) ?? "nil"])
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)

                let composerReady = try await waitFor(
                    javaScript: "document.querySelectorAll('textarea,[contenteditable=\"true\"]').length > 0",
                    timeout: 180,
                    label: "composer"
                )
                write(["event": "composer", "found": composerReady])
                if let installed = try? await evaluate(Self.errorRecorderScript()) {
                    write(["event": "error_recorder", "result": (installed as? String) ?? "nil"])
                }

                // Attach every file, one at a time, recording each outcome. One at
                // a time because the composer's guards (`machineBusy`, upload
                // queue) are per-call, and a batch would make a single refusal
                // look like all of them failing.
                for name in attachments {
                    // The agent's working directory is the harness's
                    // `default-workspace` inside the app workspace, and that is
                    // where the acceptance stages fixtures. Resolving against
                    // `workspace` itself finds nothing and the run then reports a
                    // prompt with zero images — which is exactly what happened
                    // the first time this was driven.
                    let path = NodeRunner.shared.workspace
                        .appendingPathComponent("deepseek-harness/default-workspace")
                        .appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: path) else {
                        write(["event": "attach_missing", "file": name, "path": path.path])
                        continue
                    }
                    let base64 = data.base64EncodedString()
                    let type = Self.mimeTypeForName(name)
                    _ = try? await evaluate(Self.attachBeginScript(name, mimeType: type, totalBytes: base64.count))
                    let chunkSize = 400_000
                    var offset = base64.startIndex
                    var chunks = 0
                    while offset < base64.endIndex {
                        let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
                        let piece = String(base64[offset..<end])
                        // Base64's alphabet contains no quote and no backslash, so
                        // the piece goes into a single-quoted literal as-is. It is
                        // still concatenated rather than interpolated into a
                        // template so a future alphabet change cannot silently
                        // break the escaping.
                        let script = "(function(){ window.__dshAttachAppend('" + piece + "'); })();"
                        _ = try? await evaluate(script)
                        offset = end
                        chunks += 1
                    }
                    let outcome = try? await evaluate(Self.attachCommitScript())
                    write([
                        "event": "attach",
                        "file": name,
                        "bytes": data.count,
                        "base64Length": base64.count,
                        "chunks": chunks,
                        "outcome": (outcome as? String) ?? "nil",
                    ])
                    // The change event runs a React transition and, for an image,
                    // a `FileReader` encode later at submit time. Give the rail a
                    // moment to render before reading it back.
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let rail = try? await evaluate(Self.attachmentRailScript())
                    write(["event": "rail", "after": name, "state": (rail as? String) ?? "nil"])
                }

                _ = webView.becomeFirstResponder()
                try await Task.sleep(nanoseconds: 400_000_000)
                let typed = try await evaluate(Self.typeAndSendScript(prompt))
                write(["event": "typed", "result": typed])
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let sent = try? await evaluate(Self.sendScript())
                write(["event": "sent", "result": (sent as? String) ?? "nil"])
                if ((sent as? String) ?? "").hasPrefix("send-disabled") {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let retried = try? await evaluate(Self.sendScript())
                    write(["event": "sent_retry", "result": (retried as? String) ?? "nil"])
                }

                // Record what the UI said about the prompt while it lands: an
                // attachment refusal arrives as a toast, and a rejected prompt as
                // a composer error. Both are gone by the time the reply streams.
                for attempt in 1...6 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let state = try? await evaluate(Self.toastProbeScript())
                    write(["event": "toast_watch", "attempt": attempt, "state": (state as? String) ?? "nil"])
                    // Page-side exceptions are the only witness when a submission
                    // is abandoned silently; drained every poll so the moment of
                    // failure is visible, not just that it happened.
                    if let errors = try? await evaluate(Self.drainErrorScript()) as? [String], !errors.isEmpty {
                        write(["event": "page_errors", "attempt": attempt, "errors": errors])
                    }
                }

                let deadline = Date().addingTimeInterval(timeout)
                var last = -1
                var growth = 0
                while Date() < deadline {
                    let probe = try await evaluate(Self.probeScript(keyword))
                    if let dict = probe as? [String: Any],
                       let length = dict["length"] as? Int {
                        let done = dict["done"] as? Bool ?? false
                        if length > last + 1 {
                            growth += 1
                            last = length
                            samples.append(["t": Date().timeIntervalSince1970, "length": length, "growth": growth])
                        }
                        if done {
                            write(["event": "reply_complete", "length": length, "growth": growth])
                            break
                        }
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                write([
                    "event": "finish",
                    "growth": growth,
                    "samples": samples,
                    "finalText": (try? await evaluate("document.body.innerText.slice(-2000)")) ?? "",
                ])
            } catch {
                write(["event": "error", "message": "\(error)"])
            }
        }
    }

    /// Media type by extension, matching what the attachment UI accepts.
    static func mimeTypeForName(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "application/octet-stream"
        }
    }

    /// Start a page-side attachment buffer.
    static func attachBeginScript(_ name: String, mimeType: String, totalBytes: Int) -> String {
        let safeName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          window.__dshAttach = { name: '\(safeName)', type: '\(mimeType)', chunks: [], total: \(totalBytes) };
          // Appends arrive as separate evaluations because one script literal of
          // ~20 MB is slow to parse and can be truncated in transit.
          window.__dshAttachAppend = function (piece) { window.__dshAttach.chunks.push(piece); };
          return 'begun:' + window.__dshAttach.name + ':' + \(totalBytes);
        })();
        """
    }

    /// Assemble the buffered chunks into a `File` and hand it to the page's own
    /// hidden file input, then dispatch the change event the composer listens for.
    ///
    /// The `input.files` property is read-only, so a `DataTransfer` is used as the
    /// documented way to give it a real `FileList`. The element is found through
    /// the same ancestor as the composer so this cannot pick up an unrelated
    /// file input on the page.
    static func attachCommitScript() -> String {
        """
        (function () {
          const state = window.__dshAttach;
          if (!state) return 'no-buffer';
          const binary = atob(state.chunks.join(''));
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
          const file = new File([bytes], state.name, { type: state.type });
          const inputs = Array.from(document.querySelectorAll('input[type=file]'));
          if (inputs.length === 0) return 'no-file-input';
          const input = inputs[0];
          const transfer = new DataTransfer();
          transfer.items.add(file);
          input.files = transfer.files;
          input.dispatchEvent(new Event('change', { bubbles: true }));
          window.__dshAttach = undefined;
          return 'committed:' + file.name + ':' + file.size + ':' + file.type;
        })();
        """
    }

    /// Describe the attachment rail: how many chips, and what they say.
    static func attachmentRailScript() -> String {
        """
        (function () {
          const imgs = Array.from(document.querySelectorAll('img')).filter((i) => (i.src || '').startsWith('blob:'));
          const body = document.body.innerText || '';
          const cards = Array.from(document.querySelectorAll('button')).filter((b) => {
            const label = (b.getAttribute('aria-label') || '');
            return label.indexOf('移除') >= 0 || label.indexOf('Remove') >= 0;
          });
          return JSON.stringify({ previews: imgs.length, removeButtons: cards.length, bodyLength: body.length });
        })();
        """
    }

    /// Install a page-side recorder for unhandled errors and rejected promises.
    ///
    /// WHY: when a prompt fails at a point that swallows the error (a React
    /// transition, an abandoned submission), the UI shows nothing and the turn
    /// simply does not start. That is indistinguishable from "the click missed".
    /// This captures the exception text itself, which is the only thing that
    /// names the real cause.
    static func errorRecorderScript() -> String {
        """
        (function () {
          if (window.__dshErrors !== undefined) return 'already';
          window.__dshErrors = [];
          window.addEventListener('error', (e) => {
            window.__dshErrors.push('error: ' + (e.message || String(e.error)));
          });
          window.addEventListener('unhandledrejection', (e) => {
            const r = e.reason;
            window.__dshErrors.push('rejection: ' + (r && (r.code || r.message) ? ((r.code ? r.code + ': ' : '') + (r.message || '')) : String(r)));
          });
          const originalError = console.error;
          console.error = function (...args) {
            try { window.__dshErrors.push('console.error: ' + args.map((a) => (a && a.message) ? a.message : String(a)).join(' ').slice(0, 500)); } catch (_) {}
            return originalError.apply(console, args);
          };
          return 'installed';
        })();
        """
    }

    /// Read and clear the recorded page errors.
    static func drainErrorScript() -> String {
        "(function () { if (window.__dshErrors === undefined) return []; const out = window.__dshErrors.slice(); window.__dshErrors.length = 0; return out; })();"
    }

    /// Read the structured prompt failure the UI keeps but does not show.
    ///
    /// The composer's toast prints only `error.message`; the RPC failure's
    /// `details` carries the real one-line cause (`String(error)` from the Host's
    /// own catch), and for `session/attachment-invalid` it also carries the
    /// stable `reason` code. Reading it here is the difference between "prompt
    /// rejected" and "the image could not be decoded".
    static func promptErrorScript() -> String {
        """
        (function () {
          // The session snapshot is React-owned; find its promptError through
          // the rendered text plus any global the module system exposes. The
          // DOM path is the reliable one: DSH renders the message there.
          const text = document.body.innerText || '';
          const match = text.match(/prompt rejected[^\n]*/);
          return JSON.stringify({ rendered: match === null ? null : match[0] });
        })();
        """
    }

    /// Read any visible toast or composer error text.
    static func toastProbeScript() -> String {
        """
        (function () {
          const text = (document.body.innerText || '');
          const hints = ['不支持', '过大', '失败', '错误', 'unsupported', 'too large', 'failed', 'error'];
          const hits = hints.filter((h) => text.toLowerCase().indexOf(h.toLowerCase()) >= 0);
          return JSON.stringify({ hints: hits, tail: text.slice(-400) });
        })();
        """
    }

    // MARK: - JavaScript


    /// Capture what the page sees when an RPC fails, before the page runs.
    ///
    /// Why this exists: the workspace picker opens, a row is pressed, and the
    /// composer stays disabled. From the outside that is indistinguishable
    /// between "the click never reached React", "the Host refused to create a
    /// session", and "the session was created and the view did not switch". The
    /// console is the only place that difference is visible, and WKWebView does
    /// not forward it anywhere by default.
    ///
    /// Installed at document start (see `DSHWebView.makeUIView`) so nothing
    /// early is lost, and only under `-DSHPortCTestDrive 1`.
    ///
    /// @returns JavaScript source installing the recorder.
    static func diagnosticsBootstrapScript() -> String {
        """
        (function () {
          const log = [];
          const MAX = 400;
          const push = (kind, text) => {
            if (log.length >= MAX) return;
            log.push({ kind, text: String(text).slice(0, 1200), t: Date.now() });
          };
          window.__dshDiag = {
            log,
            // Snapshot with the counters reset, so a caller reads only what
            // happened since the previous read.
            drain: () => { const out = log.slice(); log.length = 0; return out; },
          };
          const wrap = (name) => {
            const original = console[name];
            console[name] = function (...args) {
              try {
                push(name, args.map((a) => {
                  if (a instanceof Error || (a && typeof a === 'object' && typeof a.message === 'string' && typeof a.stack === 'string')) {
                    // A RemoteError carries its classification OUTSIDE the
                    // message: `code`, `details`, and often a `cause` chain. A
                    // bare stack prints "Error" with an empty message and hides
                    // exactly the fact needed to tell a refused create from a
                    // broken transport.
                    const parts = [String(a.name || 'Error') + ': ' + String(a.message || '(no message)')];
                    for (const key of ['code', 'details', 'data', 'status', 'rpcError']) {
                      if (a[key] !== undefined) { try { parts.push(key + '=' + JSON.stringify(a[key])); } catch (e) { parts.push(key + '=<unserializable>'); } }
                    }
                    if (a.cause !== undefined) { try { parts.push('cause=' + JSON.stringify(String(a.cause && a.cause.message ? a.cause.message : a.cause))); } catch (e) { parts.push('cause=<unserializable>'); } }
                    for (const key of Object.keys(a)) {
                      if (['name','message','stack','code','details','data','status','rpcError','cause'].indexOf(key) >= 0) continue;
                      try { const value = a[key]; if (typeof value !== 'function' && typeof value !== 'object') parts.push(key + '=' + JSON.stringify(value)); } catch (e) { /* hostile getter */ }
                    }
                    if (a.stack) parts.push('at ' + String(a.stack).split('\n').slice(0, 4).join(' | '));
                    return parts.join(' ');
                  }
                  if (typeof a === 'object' && a !== null) { try { return JSON.stringify(a); } catch (e) { return String(a); } }
                  return String(a);
                }).join(' '));
              } catch (e) { /* a diagnostics hook must never break the page */ }
              return original.apply(this, args);
            };
          };
          ['error', 'warn'].forEach(wrap);
          window.addEventListener('error', (e) => push('error-event', (e.message || '') + ' @ ' + (e.filename || '')));
          window.addEventListener('unhandledrejection', (e) => {
            const r = e.reason;
            push('unhandledrejection', (r && (r.stack || r.message)) || String(r));
          });
          // The Host's RPC surface rides this page's own fetch and WebSocket. A
          // non-2xx HTTP answer and a failed socket are the two ways a session
          // creation fails, and both are invisible without this.
          const originalFetch = window.fetch;
          if (typeof originalFetch === 'function') {
            window.fetch = function (...args) {
              const target = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '?';
              return originalFetch.apply(this, args).then((response) => {
                if (!response.ok) push('fetch', 'HTTP ' + response.status + ' ' + target);
                return response;
              }, (error) => {
                push('fetch-failed', target + ' ' + String(error));
                throw error;
              });
            };
          }
          const OriginalWebSocket = window.WebSocket;
          if (typeof OriginalWebSocket === 'function') {
            window.WebSocket = function (...args) {
              const socket = new OriginalWebSocket(...args);
              const target = String(args[0]);
              socket.addEventListener('close', (event) => {
                push('ws-close', target + ' code=' + event.code + ' reason=' + (event.reason || '') + ' clean=' + event.wasClean);
              });
              socket.addEventListener('error', () => push('ws-error', target));
              return socket;
            };
            window.WebSocket.prototype = OriginalWebSocket.prototype;
            Object.assign(window.WebSocket, OriginalWebSocket);
          }
        })();
        """
    }

    /// Read and clear the page's own diagnostics log.
    ///
    /// @returns the recorded entries, oldest first.
    static func drainDiagnosticsScript() -> String {
        "(function () { return window.__dshDiag === undefined ? [] : window.__dshDiag.drain(); })();"
    }

    /// Probe diagnostic state: localStorage, cookies, and the network surface.
    ///
    /// Used while investigating why a programmatic workspace click is ignored:
    /// it separates "the UI never stored the choice" from "the UI stored it and
    /// the composer still refuses to appear".
    static func diagnosticScript() -> String {
        """
        (function () {
          const storage = {};
          try {
            for (let i = 0; i < localStorage.length; i += 1) {
              const k = localStorage.key(i);
              storage[k] = String(localStorage.getItem(k)).slice(0, 200);
            }
          } catch (e) { storage.error = String(e); }
          const session = {};
          try {
            for (let i = 0; i < sessionStorage.length; i += 1) {
              const k = sessionStorage.key(i);
              session[k] = String(sessionStorage.getItem(k)).slice(0, 200);
            }
          } catch (e) { session.error = String(e); }
          return {
            localStorage: storage,
            sessionStorage: session,
            cookieNames: document.cookie.split(';').map((c) => c.split('=')[0].trim()).filter(Boolean),
            inputish: Array.from(document.querySelectorAll('input,textarea,[contenteditable]')).map((el) => ({
              tag: el.tagName, type: el.type || '', ph: el.placeholder || '',
              disabled: !!el.disabled, cls: (el.className || '').toString().slice(0, 80),
            })),
            disabledButtons: Array.from(document.querySelectorAll('button')).filter((b) => b.disabled)
              .map((b) => b.getAttribute('aria-label') || (b.innerText || '').trim().slice(0, 30)),
          };
        })();
        """
    }

    /// Describe the clickable surface: buttons, comboboxes and menus.
    private static func dumpScript() -> String {
        """
        (function () {
          const describe = (el) => ({
            tag: el.tagName,
            text: (el.innerText || '').trim().slice(0, 60),
            label: el.getAttribute('aria-label') || '',
            role: el.getAttribute('role') || '',
            disabled: !!el.disabled,
          });
          return {
            url: location.href.replace(/token=[^&]+/, 'token=<redacted>'),
            bodyText: (document.body.innerText || '').slice(0, 1200),
            buttons: Array.from(document.querySelectorAll('button,[role="button"]')).map(describe).slice(0, 30),
            combos: Array.from(document.querySelectorAll('[role="combobox"],select')).map(describe),
            textareas: Array.from(document.querySelectorAll('textarea,[contenteditable="true"]')).map(describe),
          };
        })();
        """
    }

    /// Open the workspace picker and press one row.
    ///
    /// WHY TWO CALLS WITH A PAUSE BETWEEN. The composer's workspace row is a
    /// React popup: `pointerdown` on the trigger opens it, and the row it lists
    /// only exists after React has rendered that state. An earlier version did
    /// the press, the row lookup and the release inside one synchronous
    /// evaluation, and it could never work: the busy-wait held the JS thread, so
    /// React never got a frame to mount the row, and the lookup always saw an
    /// empty popup. It reported `no-workspace-items` — which at least named the
    /// right step, unlike the synthetic-click version before it that reported
    /// success while nothing had been chosen.
    ///
    /// So: press the trigger, return; the caller sleeps; then press the row.
    /// Both dispatches use a full pointer sequence with `pointerType: 'touch'`
    /// and a real `pointerId`, because React's delegated listeners ignore a bare
    /// `MouseEvent`.
    ///
    /// @param phase - `"open"` for the trigger, `"row"` for the menu entry.
    /// @param label - the row text to press, for phase `"row"`.
    /// @returns JavaScript source whose result is an outcome string.
    static func workspaceScript(phase: String, label: String = "") -> String {
        let wanted = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
          const press = (el) => {
            const rect = el.getBoundingClientRect();
            const init = {
              bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: 1, pointerId: 1, pointerType: 'touch', isPrimary: true,
              clientX: rect.left + rect.width / 2,
              clientY: rect.top + rect.height / 2,
            };
            el.dispatchEvent(new PointerEvent('pointerdown', init));
            el.dispatchEvent(new MouseEvent('mousedown', init));
          };
          const release = (el) => {
            const rect = el.getBoundingClientRect();
            const init = {
              bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: 0, pointerId: 1, pointerType: 'touch', isPrimary: true,
              clientX: rect.left + rect.width / 2,
              clientY: rect.top + rect.height / 2,
            };
            el.dispatchEvent(new PointerEvent('pointerup', init));
            el.dispatchEvent(new MouseEvent('mouseup', init));
            el.dispatchEvent(new MouseEvent('click', init));
          };
          try {
            if ('\(phase)' === 'open') {
              const trigger =
                document.querySelector('button[aria-label="选择工作区"]') ||
                document.querySelector('button[aria-label="Select workspace"]') ||
                Array.from(document.querySelectorAll('button,[role="button"]'))
                  .find((b) => norm(b.innerText) === '选择工作区' || norm(b.innerText) === 'Select workspace');
              if (trigger === null || trigger === undefined) return 'no-workspace-trigger';
              press(trigger);
              release(trigger);
              return 'trigger-pressed';
            }
            const wanted = '\(wanted)';
            const rows = Array.from(document.querySelectorAll(
              '[role="menuitem"],[role="option"],[role="menu"] button'
            ));
            const labels = rows.map((el) => norm(el.innerText));
            const row = rows.find((el) => norm(el.innerText) === wanted)
              || rows.find((el) => norm(el.innerText).indexOf(wanted) >= 0);
            if (row === undefined) return 'no-row:' + JSON.stringify(labels);
            press(row);
            release(row);
            return 'row-pressed:' + norm(row.innerText);
          } catch (error) {
            return 'error:' + String(error && error.message ? error.message : error);
          }
        })();
        """
    }

    /// Put text in the composer and send it.
    ///
    /// THE COMPOSER IS A LEXICAL EDITOR, NOT A TEXTAREA. Setting
    /// `element.textContent` on its contenteditable looks right in the DOM and
    /// is invisible to the editor: Lexical keeps its own state, and its
    /// listener reads `beforeinput`/`input`, not the DOM. The result was a
    /// composer that appeared to contain the prompt while the send button
    /// stayed disabled — the message never existed as far as React knew.
    ///
    /// `execCommand('insertText')` is the one operation WebKit routes through
    /// the same `beforeinput` path a real keystroke uses, so Lexical adopts it.
    /// The fallbacks exist because `execCommand` is deprecated and could stop
    /// working: a `beforeinput` with `inputType: insertText`, then a plain
    /// `input`. The return value names the path taken, so a future failure says
    /// which one broke instead of just "no reply".
    ///
    /// @param prompt - the text to enter.
    /// @returns JavaScript source whose result is the outcome string.
    private static func typeAndSendScript(_ prompt: String) -> String {
        let escaped = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function () {
          const text = '\(escaped)';
          const box = document.querySelector('[data-composer-input]')
            || document.querySelector('textarea')
            || document.querySelector('[contenteditable="true"]');
          if (!box) return 'no-composer';
          box.focus();
          let how = 'none';
          if (box.tagName === 'TEXTAREA' || box.tagName === 'INPUT') {
            const setter = Object.getOwnPropertyDescriptor(
              window.HTMLTextAreaElement.prototype, 'value').set;
            setter.call(box, text);
            box.dispatchEvent(new Event('input', { bubbles: true }));
            box.dispatchEvent(new Event('change', { bubbles: true }));
            how = 'textarea-setter';
          } else {
            // TRY THE PASTE COMMAND FIRST.
            //
            // This composer is a Lexical editor, and Lexical owns its own state:
            // `textContent`, `innerText` and even `execCommand('insertText')`
            // leave that state empty while changing the DOM, which is exactly
            // the observed shape (rendered=0, send button still disabled).
            //
            // DSH registers its own PASTE_COMMAND handler that reads
            // `event.clipboardData` and routes the text through its own
            // `pasteText()` — the same path a real paste takes, including its
            // chip and attachment bookkeeping. A synthetic `paste` event with a
            // populated `DataTransfer` therefore reaches the editor's real
            // insert path rather than fighting it.
            const selectionForPaste = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(box);
            range.collapse(false);
            selectionForPaste.removeAllRanges();
            selectionForPaste.addRange(range);
            try {
              const clipboard = new DataTransfer();
              clipboard.setData('text/plain', text);
              const paste = new ClipboardEvent('paste', {
                bubbles: true, cancelable: true, clipboardData: clipboard,
              });
              box.dispatchEvent(paste);
              if (paste.defaultPrevented) how = 'paste-command';
            } catch (error) { /* ClipboardEvent is not constructible here */ }

            if (how === 'none') {
              // A real keystroke, as far as WebKit is concerned: this is the one
              // documented way to drive the browser's own editing machinery, and
              // it is what the previous attempt used. Kept as a fallback, not the
              // first choice, because it depends on the view being first
              // responder and on WebKit still implementing the command.
              try {
                if (document.execCommand('insertText', false, text)) how = 'execCommand-insertText';
              } catch (error) { /* deprecated */ }
            }
            if (how === 'none') {
              box.textContent = text;
              box.dispatchEvent(new InputEvent('input', {
                bubbles: true, inputType: 'insertText', data: text,
              }));
              how = 'textContent-fallback';
            }
          }
          const current = (box.innerText || box.value || '').length;
          const editable = box.isContentEditable === true
            || (box.tagName === 'TEXTAREA' && !box.readOnly)
            || (box.tagName === 'INPUT' && !box.readOnly);
          return how + '|rendered=' + current + '|editable=' + editable;
        })();
        """
    }

    /// Press the approval dialog's positive button, if one is on screen.
    ///
    /// Returns `no-dialog` when none is present, so the caller can stop waiting
    /// without treating "nothing to approve" as a failure. The label match is on
    /// the two documented captions ("允许一次" / "Allow once") rather than on
    /// position, because a refusal option sits beside it and clicking that one
    /// would silently deny the very command under test.
    ///
    /// @returns JavaScript source whose result is the outcome string.
    static func approveScript() -> String {
        """
        (function () {
          const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
          const buttons = Array.from(document.querySelectorAll('button,[role="button"]'));
          const allow = buttons.find((b) => {
            const text = norm(b.innerText);
            return text === '允许一次' || text === 'Allow once' || text === '允许' || text === 'Allow';
          });
          if (allow === undefined) {
            const anyDialog = document.body.innerText.indexOf('等待审批') >= 0
              || document.body.innerText.indexOf('Awaiting approval') >= 0;
            return anyDialog ? 'dialog-without-allow-button' : 'no-dialog';
          }
          const rect = allow.getBoundingClientRect();
          const init = {
            bubbles: true, cancelable: true, composed: true, button: 0,
            buttons: 1, pointerId: 1, pointerType: 'touch', isPrimary: true,
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height / 2,
          };
          allow.dispatchEvent(new PointerEvent('pointerdown', init));
          allow.dispatchEvent(new MouseEvent('mousedown', init));
          allow.dispatchEvent(new PointerEvent('pointerup', init));
          allow.dispatchEvent(new MouseEvent('mouseup', init));
          allow.dispatchEvent(new MouseEvent('click', init));
          return 'clicked-allow:' + norm(allow.innerText);
        })();
        """
    }

    /// Click the composer's send button, or report why it is still disabled.
    ///
    /// Split from the insertion on purpose: Lexical applies the edit inside a
    /// React transition, so the DOM text and the button's `disabled` flag are a
    /// frame behind the call that made the change. Reading them inside the same
    /// synchronous evaluation reports a stale zero and a button that "never"
    /// enabled — which is what an earlier version did, and it looked like the
    /// insertion had failed when it had not.
    ///
    /// @returns JavaScript source whose result is the outcome string.
    private static func sendScript() -> String {
        """
        (function () {
          const buttons = Array.from(document.querySelectorAll('button'));
          const send = buttons.find((b) => {
            const label = (b.getAttribute('aria-label') || b.title || '').trim();
            return label === '发送消息' || label === 'Send message';
          });
          const box = document.querySelector('[data-composer-input]')
            || document.querySelector('textarea')
            || document.querySelector('[contenteditable="true"]');
          const rendered = box === null ? -1 : (box.innerText || box.value || '').length;
          if (send === undefined) return 'no-send-button|rendered=' + rendered;
          if (send.disabled) return 'send-disabled|rendered=' + rendered;
          send.click();
          return 'clicked-send|rendered=' + rendered;
        })();
        """
    }

    private static func probeScript(_ keyword: String) -> String {
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          const text = document.body.innerText || '';
          return { length: text.length, done: text.indexOf('\(escaped)') >= 0 };
        })();
        """
    }

    // MARK: - Plumbing

    private func evaluate(_ script: String) async throws -> Any? {
        guard let webView else { throw DriverError.noWebView }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func waitFor(javaScript: String, timeout: TimeInterval, label: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flag = try await evaluate(javaScript) as? Bool, flag { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw DriverError.timeout(label)
    }

    private func write(_ record: [String: Any]) {
        var payload: [String: Any] = record
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        samples.append(payload)
        flush()
    }

    /// Record an event that must survive a scripted run's `samples` reset.
    private func writePrelude(_ record: [String: Any]) {
        var payload: [String: Any] = record
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        prelude.append(payload)
        flush()
    }

    private func flush() {
        if let data = try? JSONSerialization.data(
            withJSONObject: ["prelude": prelude, "events": samples], options: [.prettyPrinted]
        ) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}

enum DriverError: Error, CustomStringConvertible {
    case noWebView
    case timeout(String)

    var description: String {
        switch self {
        case .noWebView: return "no web view registered"
        case .timeout(let label): return "timed out waiting for \(label)"
        }
    }
}
