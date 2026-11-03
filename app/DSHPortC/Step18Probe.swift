//
//  Step18Probe.swift
//  DSHPortC
//
//  Step 18's instrument: a probe that can be asked a question about whatever is
//  on screen right now, from outside the app, without a rebuild.
//
//  WHY THIS SHAPE
//  --------------
//  The interaction sweep has to look at roughly twenty different screens (composer
//  row menus, the slash menu, the session list, six settings pages, the right
//  panel, an approval card, a question card, a toast, a modal…). Two properties
//  matter more than elegance:
//
//    * The SAME measurement has to run in every one of those states, otherwise
//      the "before/after" table compares different questions.
//    * Asking the question must not require relaunching the app, because most of
//      those states only exist after several taps, and a rebuild-and-relaunch
//      loop per state would make the sweep too slow to actually do.
//
//  So the probe exposes a tiny file channel: the host drops
//  `Documents/step18-cmd.json` (`{"id": "...", "script": "..."}`) and the probe
//  writes `Documents/step18-out-<id>.json` with whatever the script returned.
//  The script is JavaScript evaluated in the app's own web view — the same
//  context DSH's front end runs in, so what it sees is what a person sees.
//
//  The audit itself (`Self.auditScript()`) is the one script the report's numbers
//  come from. A host file `Documents/step18-audit.js`, when present, replaces it
//  so the script can be iterated on without a rebuild; the built-in copy is what
//  a fresh launch uses, and every evidence file records which of the two ran.
//
//  THE WATCHER
//  -----------
//  With `-DSHPortEStep18Watch 1` the probe also samples on its own, once per
//  state change, so a run driven by REAL touches (XCUITest) — which cannot ask
//  the app anything — still produces a per-screen record. The signature it keys
//  on is built from DSH's own `data-*` markers, not class names: class names are
//  build output, the data attributes are what DSH's own code navigates by.
//
//  GATING
//  ------
//  Nothing here runs unless the app is launched with `-DSHPortEStep18 1`, so a
//  normal launch never reaches this code.
//

import Foundation
import UIKit
import WebKit

@MainActor
final class Step18Probe {
    static let shared = Step18Probe()

    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEStep18") == 1
    }

    /// Tag for the evidence files, so two runs do not overwrite each other.
    static var tag: String {
        UserDefaults.standard.string(forKey: "DSHPortEStep18Tag") ?? ""
    }

    /// Sample once per state change, without being asked.
    static var watchEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEStep18Watch") == 1
    }

    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var lastCommandID = ""
    private var snapshots: [[String: Any]] = []
    private var lastSignature = ""
    private var auditSource = "builtin"
    private var busy = false

    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private func file(_ name: String) -> URL { documents.appendingPathComponent(name) }
    private var commandURL: URL { file("step18-cmd.json") }
    private var overrideURL: URL { file("step18-audit.js") }

    private var outputURL: URL {
        let suffix = Self.tag.isEmpty ? "" : "-\(Self.tag)"
        return file("step18-probe\(suffix).json")
    }

    // MARK: - Setup

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
        // A stale command from a previous launch would be executed again the
        // moment this one boots, which would look like the app doing something
        // nobody asked for.
        try? FileManager.default.removeItem(at: commandURL)
        if let script = try? String(contentsOf: overrideURL, encoding: .utf8), !script.isEmpty {
            auditSource = "override"
        }
        writeStatus()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollCommand()
                // The watcher rides the same tick as the command channel: a run
                // driven by real touches cannot ask the app anything, so without
                // this the per-screen record would be missing exactly the states
                // that need real fingers to reach.
                await self?.sampleIfStateChanged()
            }
        }
    }

    deinit { pollTimer?.invalidate() }

    // MARK: - The command channel

    private func pollCommand() async {
        guard let webView, !busy else { return }
        guard let data = try? Data(contentsOf: commandURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = parsed["id"] as? String, !id.isEmpty, id != lastCommandID,
              let script = parsed["script"] as? String
        else { return }
        lastCommandID = id
        busy = true
        defer { busy = false }
        let started = Date()
        // STEP 21: TWO NATIVE COMMANDS, so a question about the APP's own state can
        // be answered from the app's process.
        //
        // The reason is the pasteboard. A UI test runs as its own application, so
        // the `UIPasteboard` it reads is the RUNNER's, not the app's: a page that
        // copies with `navigator.clipboard.writeText` writes into the app's
        // pasteboard and a test looking at its own sees nothing. Measured that way
        // round on this build: the page's own call resolves `ok`, and the runner's
        // pasteboard stays empty. Reading it HERE is the only honest check, and it
        // costs one branch.
        //
        //   DSHPortE:pasteboard       -> the app's pasteboard string
        //   DSHPortE:clearPasteboard  -> what it held, and then empties it
        //
        // The second one is what makes a copy provable: without it a test could
        // "find" a value left over from an earlier step.
        let value: Any?
        if script.hasPrefix("DSHPortE:") {
            let command = String(script.dropFirst("DSHPortE:".count))
            switch command {
            case "pasteboard":
                value = UIPasteboard.general.string ?? ""
            case "clearPasteboard":
                let previous = UIPasteboard.general.string ?? ""
                UIPasteboard.general.string = ""
                value = previous
            default:
                value = "unknown-native-command:\(command)"
            }
        } else {
            value = await evaluate(script)
        }
        let reply: [String: Any] = [
            "id": id,
            "ok": value != nil,
            "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
            "at": ISO8601DateFormatter().string(from: Date()),
            "value": value ?? "nil",
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted]) {
            try? encoded.write(to: file("step18-out-\(id).json"), options: .atomic)
        }
        _ = webView
    }

    // MARK: - The watcher

    /// One automatic sample per state change, for runs driven by real touches.
    func sampleIfStateChanged() async {
        guard Self.watchEnabled, snapshots.count < 80 else { return }
        guard let signature = await evaluate(Self.signatureScript()) as? String else { return }
        guard signature != lastSignature else { return }
        lastSignature = signature
        guard let raw = await evaluate(currentAuditScript()) as? String,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var record = parsed
        record["signature"] = signature
        record["at"] = ISO8601DateFormatter().string(from: Date())
        record["auditSource"] = auditSource
        record["keyboard"] = keyboardFacts()
        snapshots.append(record)
        flush()
    }

    private func flush() {
        let payload: [String: Any] = [
            "probe": "step18",
            "tag": Self.tag,
            "auditSource": auditSource,
            "device": [
                "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
                "name": UIDevice.current.name,
                "systemVersion": UIDevice.current.systemVersion,
            ],
            "snapshots": snapshots,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: outputURL, options: .atomic)
        }
    }

    private func writeStatus() {
        let payload: [String: Any] = [
            "enabled": true,
            "tag": Self.tag,
            "watch": Self.watchEnabled,
            "auditSource": auditSource,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: file("step18-probe-status.json"), options: .atomic)
        }
    }

    /// Whether the keyboard is up, and how much of the screen it took.
    ///
    /// The audit is about what a finger can reach, and half of it changes when the
    /// keyboard appears — so every sample records the keyboard state next to the
    /// DOM numbers rather than leaving the reader to infer it.
    private func keyboardFacts() -> [String: Any] {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow }
        var facts: [String: Any] = [
            "interfaceOrientation": orientationName(scene?.interfaceOrientation),
        ]
        if let window {
            facts["windowWidth"] = Double(window.bounds.width)
            facts["windowHeight"] = Double(window.bounds.height)
            facts["safeAreaTop"] = Double(window.safeAreaInsets.top)
            facts["safeAreaBottom"] = Double(window.safeAreaInsets.bottom)
            if let webView {
                let rect = webView.convert(webView.bounds, to: window)
                facts["webViewFrame"] = [
                    "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                    "width": Double(rect.width), "height": Double(rect.height),
                ]
            }
        }
        return facts
    }

    private func orientationName(_ orientation: UIInterfaceOrientation?) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        default: return "unknown"
        }
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

    private func currentAuditScript() -> String {
        if let script = try? String(contentsOf: overrideURL, encoding: .utf8), !script.isEmpty {
            return script
        }
        return Self.auditScript()
    }

    /// A short label for "which screen is this", built from DSH's own markers.
    ///
    /// Deliberately not the URL hash and not a class name: the app is a single
    /// document whose overlays, panels and routes are all in-page state, and the
    /// `data-*` attributes are what DSH itself navigates by.
    static func signatureScript() -> String {
        """
        (function () {
          const on = (selector) => document.querySelector(selector) !== null;
          const parts = [];
          const push = (name, value) => parts.push(name + '=' + value);
          const sidebar = document.querySelector('[data-sidebar-collapsed]');
          push('sidebar', sidebar === null ? 'absent' : sidebar.getAttribute('data-sidebar-collapsed'));
          const right = document.querySelector('[data-sidebar-right-panel]');
          push('right', right === null ? 'absent' : (right.getAttribute('data-sidebar-right-mode') || 'open'));
          const rc = document.querySelector('[data-rightbar-collapsed]');
          push('rightbar', rc === null ? 'absent' : rc.getAttribute('data-rightbar-collapsed'));
          push('tabs', document.querySelectorAll('[data-dockkit-tab]').length);
          push('dialogs', document.querySelectorAll('[role="dialog"], [data-modal-autofocus]').length);
          push('menus', document.querySelectorAll('[role="menu"], [data-trigger-menu]').length);
          push('approval', document.querySelectorAll('[data-approval-key]').length);
          push('question', document.querySelectorAll('[data-question-key]').length);
          push('settings', document.querySelectorAll('[data-slot][data-slot="settings"], [data-dsh-boot]').length);
          push('composerOverlay', document.querySelectorAll('[data-composer-overlay]').length);
          push('rows', document.querySelectorAll('[data-row-key]').length);
          push('messages', document.querySelectorAll('[data-chat-flow-kind]').length);
          push('focus', (document.activeElement || {}).tagName || 'none');
          // The visible heading of a modal or panel, which is the most readable
          // name for "which page is this".
          const heading = document.querySelector('[role="dialog"] h1, [role="dialog"] h2, [role="dialog"] h3, [data-sidebar-right-panel] h1, [data-sidebar-right-panel] h2');
          push('heading', heading === null ? '' : (heading.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40));
          push('stats', document.querySelectorAll('[data-session-stats-usage]').length);
          return parts.join('|');
        })();
        """
    }

    /// The audit: the four questions the task asks, plus the geometry needed to
    /// read the answers.
    ///
    /// WHAT IT LOOKS AT, and why each one is a runtime fact rather than a CSS
    /// fact:
    ///
    ///   1. Clickable targets under 44 × 44 pt. The size a finger gets is the
    ///      *rendered* rect after every flex/grid/gap rule has run, and iOS's own
    ///      guidance is 44 pt; nothing in the source says what that comes out as.
    ///   2. Elements whose box escapes the visual viewport. Containment depends on
    ///      the keyboard, the safe area and the panel widths at the moment of the
    ///      sample.
    ///   3. Text holders with `scrollWidth > clientWidth` and no way to scroll.
    ///      Whether an ancestor scrolls is a computed-style question.
    ///   4. Controls that only appear on hover. The evidence is in the
    ///      stylesheets: a `:hover` rule that changes opacity/visibility/display
    ///      for a descendant is exactly the desktop idiom that leaves a phone
    ///      user with no way to reach the control.
    static func auditScript() -> String {
        """
        (function () {
          const vv = window.visualViewport || null;
          const vw = window.innerWidth;
          const vh = vv === null ? window.innerHeight : Math.round(vv.height);
          const vvTop = vv === null ? 0 : Math.round(vv.offsetTop);
          const vvBottom = vvTop + vh;
          const EPS = 0.5;

          const round = (n) => Math.round(n * 10) / 10;

          const visible = (el) => {
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (parseFloat(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            return true;
          };

          // A readable name for an element: DSH's own data attributes first,
          // because they are stable across builds, then role/tag/text.
          const name = (el) => {
            const bits = [];
            for (const attr of el.attributes) {
              if (attr.name.indexOf('data-') === 0) bits.push('[' + attr.name + (attr.value ? '=' + attr.value.slice(0, 24) : '') + ']');
            }
            let tag = el.tagName.toLowerCase();
            if (el.getAttribute('role')) tag += ':' + el.getAttribute('role');
            const aria = el.getAttribute('aria-label');
            if (aria) bits.push('aria=' + aria.slice(0, 30));
            const text = (el.innerText || el.value || '').replace(/\\s+/g, ' ').trim();
            if (text) bits.push('"' + text.slice(0, 40) + '"');
            return tag + (bits.length ? ' ' + bits.slice(0, 4).join(' ') : '');
          };

          // Every element that answers a tap. Broad on purpose: on this UI a
          // <div> with an onClick is as much a button as a <button>.
          const CLICKABLE = [
            'button', 'a[href]', 'input', 'select', 'textarea', 'summary',
            '[role="button"]', '[role="link"]', '[role="tab"]', '[role="menuitem"]',
            '[role="checkbox"]', '[role="switch"]', '[role="option"]', '[role="radio"]',
            '[tabindex]:not([tabindex="-1"])', '[data-row-key]', '[data-dockkit-tab]',
            '[data-chat-flow-key] [class*="action"]', '[data-sidebar-right-toggle]',
            '[data-scroll-down]', '[data-files-row]', '[data-plugin-row]',
            '[data-open-path]', '[data-selection-focus]', '[data-composer-chip]',
          ].join(',');

          const smallTargets = [];
          const offScreen = [];
          const seen = new Set();

          const all = Array.from(document.querySelectorAll(CLICKABLE));
          for (const el of all) {
            if (seen.has(el)) continue;
            seen.add(el);
            if (!visible(el)) continue;
            const rect = el.getBoundingClientRect();
            // Only what is actually on screen: an element inside a closed panel
            // still reports a non-zero rect in some layouts.
            const onScreen = rect.bottom > vvTop && rect.top < vvBottom && rect.right > 0 && rect.left < vw;
            if (!onScreen) continue;
            const w = round(rect.width);
            const h = round(rect.height);
            if (w < 44 || h < 44) {
              smallTargets.push({ el: name(el), w: w, h: h, top: round(rect.top), left: round(rect.left) });
            }
            if (rect.left < -EPS || rect.right > vw + EPS || rect.top < vvTop - EPS || rect.bottom > vvBottom + EPS) {
              offScreen.push({
                el: name(el),
                left: round(rect.left), right: round(rect.right),
                top: round(rect.top), bottom: round(rect.bottom),
                overRight: round(rect.right - vw), overBottom: round(rect.bottom - vvBottom),
              });
            }
          }

          // Text that is wider than its box with nothing to scroll it.
          const scrollingAncestor = (el) => {
            let node = el.parentElement;
            let depth = 0;
            while (node !== null && depth < 12) {
              const style = getComputedStyle(node);
              const x = style.overflowX;
              if (x === 'auto' || x === 'scroll' || x === 'hidden') return true;
              node = node.parentElement;
              depth += 1;
            }
            return false;
          };
          const clipped = [];
          const textHolders = document.querySelectorAll('span, p, div, td, li, h1, h2, h3, h4, code, label');
          let scanned = 0;
          for (const el of textHolders) {
            if (scanned > 4000) break;
            scanned += 1;
            if (el.children.length > 0) continue;
            if (!visible(el)) continue;
            if (el.scrollWidth <= el.clientWidth + 1) continue;
            if (scrollingAncestor(el)) continue;
            const style = getComputedStyle(el);
            clipped.push({
              el: name(el),
              scrollWidth: el.scrollWidth,
              clientWidth: el.clientWidth,
              overflowX: style.overflowX,
              textOverflow: style.textOverflow,
              whiteSpace: style.whiteSpace,
              text: (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 60),
            });
          }

          // Controls that a desktop reveals on hover.
          //
          // Read out of the stylesheets rather than guessed from a class name: the
          // rule "X:hover .child { opacity: 1 }" is the desktop-only idiom, and
          // the question the report has to answer is which of those controls have
          // a touch path at all.
          const hoverOnly = [];
          const sheetErrors = [];
          const collects = (sheet) => {
            let rules;
            try { rules = sheet.cssRules; } catch (error) {
              sheetErrors.push(String(sheet.href || 'inline') + ': ' + error.name);
              return;
            }
            if (rules === null || rules === undefined) return;
            for (const rule of rules) {
              if (rule.cssRules !== undefined && rule.selectorText === undefined) {
                collects(rule);  // @media / @supports wrapper
                continue;
              }
              const selector = rule.selectorText;
              if (!selector || selector.indexOf(':hover') < 0) continue;
              const style = rule.style;
              if (!style) continue;
              const changed = [];
              for (const prop of ['opacity', 'visibility', 'display', 'pointer-events', 'transform']) {
                const value = style.getPropertyValue(prop);
                if (value) changed.push(prop + ':' + value);
              }
              if (changed.length === 0) continue;
              // Only the reveal-shaped ones: a hover that turns a control ON is
              // the desktop idiom the task names; a hover that only changes a
              // background colour is a sticky-highlight problem, counted apart.
              const reveals = changed.some((c) => c.indexOf('opacity:1') === 0 || c.indexOf('visibility:visible') === 0 || c.indexOf('pointer-events:auto') === 0);
              if (!reveals) continue;
              const rest = selector.replace(/:hover/g, '');
              let matched = 0;
              try { matched = document.querySelectorAll(rest).length; } catch (error) { matched = -1; }
              hoverOnly.push({ selector: selector.slice(0, 120), declares: changed.join(';'), matchesAtRest: matched });
            }
          };
          for (const sheet of Array.from(document.styleSheets)) collects(sheet);

          // The composer row and status line, verbatim: these are the two places
          // the task says are truncated, and a screenshot alone cannot say by how
          // much.
          const textOf = (selector) => {
            const el = document.querySelector(selector);
            if (el === null) return null;
            const rect = el.getBoundingClientRect();
            return {
              text: (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 200),
              scrollWidth: el.scrollWidth, clientWidth: el.clientWidth,
              clipped: el.scrollWidth > el.clientWidth + 1,
              w: round(rect.width), h: round(rect.height),
            };
          };

          const out = {
            at: Date.now(),
            viewport: {
              innerWidth: vw, innerHeight: window.innerHeight,
              vvWidth: vv === null ? null : round(vv.width),
              vvHeight: vh, vvOffsetTop: vvTop, vvBottom: vvBottom,
              scale: vv === null ? 1 : vv.scale,
              docScrollWidth: document.documentElement.scrollWidth,
              docClientWidth: document.documentElement.clientWidth,
              horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
            },
            counts: {
              clickable: all.length,
              smallTargets: smallTargets.length,
              offScreen: offScreen.length,
              clippedText: clipped.length,
              hoverOnlyRules: hoverOnly.length,
            },
            smallTargets: smallTargets,
            offScreen: offScreen,
            clippedText: clipped.slice(0, 40),
            hoverOnly: hoverOnly.slice(0, 60),
            sheetErrors: sheetErrors,
            composerRow: textOf('[data-composer-dock]') || textOf('[data-composer-card]'),
            statusLine: textOf('[data-session-stats-usage]') || textOf('[data-composer-stat]'),
          };
          return JSON.stringify(out);
        })();
        """
    }
}
