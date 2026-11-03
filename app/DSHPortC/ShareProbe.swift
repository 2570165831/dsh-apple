//
//  ShareProbe.swift
//  DSHPortC
//
//  Drives step 17's download, link and dialog paths from inside the page, and
//  records what happened.
//
//  WHY A PROBE AND NOT JUST A UI TEST
//  ----------------------------------
//  Two of the four download triggers cannot be reached by tapping something in
//  DSH's UI on demand: a `blob:` download and a 50 MB one are shapes a page can
//  produce but the product does not happen to produce on a button. XCUITest can
//  tap what is on screen; it cannot create a 50 MB blob. So this probe runs
//  scripted JavaScript in the app's own web view — the same context the real UI
//  runs in — and the real download/share machinery does the rest. What it proves
//  is the machinery, not a mock of it: the `<a download>` click, the blob URL,
//  the `WKDownload`, the destination file, the share sheet and the cleanup are
//  all the production path.
//
//  GATING: nothing here runs unless the app is launched with
//  `-DSHPortEShareCase <name>`. A normal launch never reaches this code, and a
//  probe launch writes exactly one evidence file into `Documents/`
//  (`DSHPortE-share.json`), which is a probe artefact like the rest.
//

import Foundation
import WebKit

@MainActor
final class ShareProbe {

    static let shared = ShareProbe()

    static var isEnabled: Bool {
        let value = UserDefaults.standard.string(forKey: "DSHPortEShareCase") ?? ""
        return !value.isEmpty
    }

    static var shareCase: String {
        UserDefaults.standard.string(forKey: "DSHPortEShareCase") ?? ""
    }

    private var webView: WKWebView?
    private var started = false
    private var facts: [String: Any] = [:]

    /// The evidence file. One name; each case overwrites it, because a UI test
    /// launches the app once per case and the container survives between
    /// launches — a shared file would be quoting whichever case ran last.
    private let reportURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DSHPortE-share.json")
    }()

    func register(_ webView: WKWebView) {
        guard Self.isEnabled else { return }
        self.webView = webView
    }

    /// Run the configured case once the page is up.
    ///
    /// Called from `ContentView`'s ready hook, so it happens after DSH has
    /// rendered rather than against an empty document.
    func runIfConfigured() {
        guard Self.isEnabled, !started, let webView else { return }
        started = true
        let name = Self.shareCase
        facts["case"] = name
        facts["startedAt"] = ISO8601DateFormatter().string(from: Date())
        write()

        Task { @MainActor in
            // The React tree finishes hydrating a moment after `didFinish`; a
            // blob download needs the origin to be the page's own, and that is
            // true as soon as the document exists, but waiting costs nothing and
            // removes one way for this to be flaky.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            switch name {
            case "export":
                await runExport(webView)
            case "export-nav":
                // The SAME route, reached by a plain navigation instead of an
                // anchor with a `download` attribute. That is the only way to
                // exercise the response-side trigger: an `<a download>` is
                // decided on the ACTION (`shouldPerformDownload`) and never
                // reaches `decidePolicyForNavigationResponse`, so testing only
                // that would leave `Content-Disposition: attachment` unproven —
                // measured, the export case's own record says
                // `trigger: shouldPerformDownload`.
                await runExportNavigation(webView)
            case "blob":
                await runScript(webView, Self.blobScript, label: "blob")
            case "data":
                await runScript(webView, Self.dataScript, label: "data")
            case "big":
                await runScript(webView, Self.bigScript, label: "big")
            case "links":
                await runScript(webView, Self.linkScript, label: "links")
            case "dialogs":
                await runScript(webView, Self.dialogScript, label: "dialogs")
            default:
                facts["error"] = "unknown case \(name)"
            }
            facts["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            write()
        }
    }

    /// `/api/session.export` — the route `dsh-session-log-export` uses.
    ///
    /// The anchor is built and clicked EXACTLY the way that plugin builds it
    /// (`SESSION_LOG_EXPORT_ROUTE` + a `download` attribute), because the point
    /// of testing this entry is the real route's headers, not a hand-made one.
    /// The session id comes in as a launch argument; the host script reads it
    /// out of the app container's DSH_HOME, so nothing here invents one.
    private func runExport(_ webView: WKWebView) async {
        let sessionId = UserDefaults.standard.string(forKey: "DSHPortESessionId") ?? ""
        facts["sessionId"] = sessionId
        write()
        guard !sessionId.isEmpty else {
            facts["error"] = "no -DSHPortESessionId; the host script reads it from DSH_HOME"
            write()
            return
        }
        let script = """
        (function () {
          const route = '/api/session.export?' + new URLSearchParams({
            sessionId: \(ShareProbe.jsString(sessionId)),
            includeDescendants: 'true',
          }).toString();
          const anchor = document.createElement('a');
          anchor.href = route;
          anchor.download = 'dsh-session-' + \(ShareProbe.jsString(sessionId)).replace(/[^A-Za-z0-9_-]/g, '_') + '.zip';
          anchor.style.display = 'none';
          document.body.appendChild(anchor);
          anchor.click();
          return route;
        })();
        """
        if let value = try? await evaluate(webView, script) as? String {
            facts["route"] = value
        } else {
            facts["route"] = "evaluation failed"
        }
        write()
    }

    /// Navigate straight at the export route, with no download attribute.
    ///
    /// The page must not be replaced: a response carrying
    /// `Content-Disposition: attachment` has to become a `WKDownload`, which is
    /// what `LinkRouter.decide(navigationResponse)` is for. If that rule were
    /// missing, this navigation would put the ZIP's bytes into the web view as a
    /// document — or show a blank page — and the record would say so.
    private func runExportNavigation(_ webView: WKWebView) async {
        let sessionId = UserDefaults.standard.string(forKey: "DSHPortESessionId") ?? ""
        facts["sessionId"] = sessionId
        write()
        guard !sessionId.isEmpty else {
            facts["error"] = "no -DSHPortESessionId; the host script reads it from DSH_HOME"
            write()
            return
        }
        let script = """
        (function () {
          const route = '/api/session.export?' + new URLSearchParams({
            sessionId: \(ShareProbe.jsString(sessionId)),
            includeDescendants: 'true',
          }).toString();
          const before = location.href;
          // A real navigation, so the RESPONSE headers are what decide. Not
          // `window.open`, not an anchor: those take the action path.
          location.href = route;
          return JSON.stringify({ before: before, route: route });
        })();
        """
        if let value = try? await evaluate(webView, script) as? String {
            facts["navigatedTo"] = value
        }
        write()
        // Give the download time to complete before the record is read again.
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        write()
    }

    private func runScript(_ webView: WKWebView, _ script: String, label: String) async {
        do {
            let value = try await evaluate(webView, script)
            facts["\(label)Result"] = describe(value)
        } catch {
            facts["\(label)Error"] = "\(error)"
        }
        write()
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func describe(_ value: Any?) -> Any {
        if let value { return String(describing: value) }
        return "nil"
    }

    private func write() {
        facts["downloads"] = DownloadCoordinator.shared.records.map { $0.asDictionary }
        guard let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: reportURL, options: .atomic)
    }

    // MARK: - Scripts

    /// A `blob:` URL with a Chinese filename, fetched through `<a download>`.
    ///
    /// This is the shape a plugin uses to hand a generated file to the browser,
    /// and the one that used to do nothing at all: a blob URL cannot be
    /// navigated to as a document, so without a download policy the tap is lost.
    static let blobScript = """
    (function () {
      const name = '中文文件名测试.txt';
      const text = 'DSH blob download\\n中文内容一行\\n' + new Date().toISOString() + '\\n';
      const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = name;
      anchor.style.display = 'none';
      document.body.appendChild(anchor);
      anchor.click();
      setTimeout(function () { URL.revokeObjectURL(url); }, 30000);
      return JSON.stringify({ name: name, bytes: blob.size, url: url.slice(0, 20) });
    })();
    """

    /// A `data:` URL. Same class of trigger, different scheme: Safari can render
    /// a `data:text/plain` page, which is why this one is worth testing
    /// separately — the rule is "data URLs download", not "unshowable ones do".
    static let dataScript = """
    (function () {
      const text = 'DSH data URL download\\n' + new Date().toISOString() + '\\n';
      const url = 'data:text/plain;charset=utf-8,' + encodeURIComponent(text);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = '数据URL测试.txt';
      anchor.style.display = 'none';
      document.body.appendChild(anchor);
      anchor.click();
      return JSON.stringify({ bytes: text.length });
    })();
    """

    /// 50 MB through the same path, so "does the app hold the whole file in
    /// memory" is answerable. The blob is built in the WEB process (a separate
    /// process from the app's Swift side); the download then streams it to disk,
    /// which is the claim under test.
    static let bigScript = """
    (function () {
      const size = 50 * 1024 * 1024;
      const chunk = new Uint8Array(1024 * 1024);
      for (let i = 0; i < chunk.length; i++) chunk[i] = 65 + (i % 26);
      const parts = [];
      for (let i = 0; i < 50; i++) parts.push(chunk);
      const blob = new Blob(parts, { type: 'application/octet-stream' });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = '大文件50MB.bin';
      anchor.style.display = 'none';
      document.body.appendChild(anchor);
      anchor.click();
      setTimeout(function () { URL.revokeObjectURL(url); }, 120000);
      return JSON.stringify({ size: blob.size });
    })();
    """

    /// `target=_blank` to an external site, and to the app's own server.
    ///
    /// The external one must leave for the system browser WITHOUT replacing this
    /// page; the local one must stay inside the app. The returned string records
    /// the page URL before and then again after a turn of the runloop, so "the
    /// page did not move" is measured rather than assumed.
    static let linkScript = """
    (function () {
      const before = location.href;
      const external = document.createElement('a');
      external.href = 'https://example.com/step17-blank';
      external.target = '_blank';
      external.rel = 'noopener';
      external.textContent = 'external';
      external.id = 'step17-external-link';
      external.style.cssText = 'position:fixed;left:4px;top:120px;z-index:99999;background:#fff;color:#000;padding:8px;font-size:14px';
      document.body.appendChild(external);
      // The click is dispatched as a real MouseEvent rather than `a.click()`, so
      // it goes through WebKit's own navigation path — which is where
      // `shouldPerformDownload` and `targetFrame == nil` are decided. A
      // synthetic `click()` on a detached-then-attached anchor does the same
      // thing, but this spelling makes it explicit that a user gesture path is
      // what is being exercised.
      external.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      return JSON.stringify({ before: before, origin: location.origin });
    })();
    """

    /// `alert` / `confirm` / `prompt`, each answered by the native panel.
    static let dialogScript = """
    (function () {
      const out = [];
      out.push('alert:' + (alert('step17 alert') === undefined ? 'returned' : 'odd'));
      out.push('confirm:' + confirm('step17 confirm'));
      const answer = prompt('step17 prompt', '默认文本');
      out.push('prompt:' + (answer === null ? 'null' : answer));
      return out.join(' | ');
    })();
    """

    /// A JavaScript string literal, including the quotes, from a Swift string.
    nonisolated static func jsString(_ value: String) -> String {
        var escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        escaped = "'" + escaped.replacingOccurrences(of: "'", with: "\\'") + "'"
        return escaped
    }
}
