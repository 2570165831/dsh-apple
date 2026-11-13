//
//  LinkRouter.swift
//  DSHPortC
//
//  What a link does, and what a page's `alert`/`confirm`/`prompt` does, in an
//  app whose whole UI is one web view.
//
//  WHY THIS EXISTS
//  ---------------
//  Three things were broken or missing, and all three come from the same place:
//  a `WKWebView` with no `createWebViewWithConfiguration:` and no
//  `WKUIDelegate` dialog methods does something worse than failing loudly.
//
//    1. `target=_blank` / `window.open`. Without `createWebViewWith…` WebKit
//       CANCELS the navigation. Six of DSH's client bundles use `window.open`:
//       the chat transcript's links, the browser sidebar, the plugin market,
//       the account/settings pages and tool output. Tapping a citation in a
//       reply therefore did nothing at all.
//    2. An ordinary link to another site. Allowed by default, which means it
//       REPLACES the DSH page inside the one web view the app has — the user
//       lands on a web page with no way back into DSH except relaunching.
//    3. `alert` / `confirm` / `prompt`. With no `WKUIDelegate` methods WebKit
//       dismisses `alert` and `prompt` immediately and answers `confirm` with
//       FALSE — silently, so a page that asks "delete this?" and checks the
//       answer takes the "no" branch and looks broken. DSH's own client code
//       does not call these today (grepped), but a plugin or a dependency can,
//       and a library that uses `confirm` is not going to tell anyone.
//
//  THE RULES
//  ---------
//    * A link to this app's own DSH server stays in the app. That includes a
//      `window.open` of one: it loads in the same web view, which is the
//      closest thing a single-web-view app has to "a new window in the app".
//    * Anything else with an http/https/mailto/tel scheme goes to the system
//      browser (`UIApplication.shared.open`). Never into this web view: the
//      DSH session is the app's content and must not be replaced by a web page.
//    * A main-frame tap on `dshportc://about` from our own server opens the
//      native About sheet. Other uses of the internal scheme are cancelled.
//    * A download (see `DownloadCoordinator`) is a download at every entry
//      point: an action that says so, a `blob:`/`data:` URL, a response header,
//      or a MIME type the web view cannot display.
//    * A popup that starts as `about:blank` and navigates itself (the OAuth
//      pattern in `dsh-client-ui-settings-account`) gets a real web view,
//      presented modally, because cancelling it would break sign-in with a
//      blank nothing. That popup follows the same rules: local stays inside it,
//      external leaves for the system browser and closes the popup.
//

import SafariServices
import UIKit
import WebKit

@MainActor
final class LinkRouter {

    static let shared = LinkRouter()

    /// The app's one web view. Set when the coordinator attaches.
    weak var webView: WKWebView?

    /// Every decision this class made, for the acceptance run. Written to
    /// `Documents/DSHPortE-links.json` only when `-DSHPortELinkProbe 1` is on.
    private var events: [[String: Any]] = []

    /// The modal web view a `window.open` produced, if one is up. Held because
    /// WebKit keeps only a weak reference to it.
    private var popup: PopupWindow?

    static var probeEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortELinkProbe") == 1
    }

    // MARK: - Deciding

    enum Decision {
        case allow
        case cancel
        case download(DownloadCoordinator.Trigger)
    }

    /// What to do with one navigation action (a tap, a form post, a script
    /// navigation).
    func decide(_ action: WKNavigationAction, onAbout: (() -> Void)? = nil) -> Decision {
        let url = action.request.url
        let scheme = (url?.scheme ?? "").lowercased()

        if scheme == "dshportc" {
            guard url?.absoluteString == "dshportc://about",
                  action.navigationType == .linkActivated,
                  action.sourceFrame.isMainFrame,
                  action.targetFrame?.isMainFrame == true,
                  let sourceURL = action.sourceFrame.request.url,
                  isOwnServer(sourceURL), let onAbout else {
                return note(.cancel, action: action, extra: ["reason": "internal-link-blocked"])
            }
            onAbout()
            return note(.cancel, action: action, extra: ["reason": "native-about"])
        }

        // 1. Download triggers WebKit can already see before the request goes
        //    out: an `<a download>`, or a `blob:`/`data:` URL that cannot be
        //    navigated to as a document.
        if action.shouldPerformDownload {
            return note(.download(.navigationActionShouldPerformDownload), action: action)
        }
        if scheme == "blob" || scheme == "data" {
            return note(.download(.responseShouldPerformDownload), action: action)
        }

        // 2. No target frame means WebKit would have asked for a new window.
        //    We do not implement that delegate path for ordinary links (we do
        //    for `about:blank` popups), so the routing has to happen here.
        if action.targetFrame == nil {
            if let url, isOwnServer(url) {
                // "A new window on the local DSH server stays in the app."
                webView?.load(action.request)
                return note(.cancel, action: action, extra: ["reason": "local-new-window-in-place"])
            }
            openExternally(url)
            return note(.cancel, action: action, extra: ["reason": "new-window-external"])
        }

        // 3. Any main-frame navigation away from the app's own server leaves
        //    the app, so the DSH session is never replaced by a web page.
        if action.targetFrame?.isMainFrame == true, let url, !isOwnServer(url), isLeavable(url) {
            openExternally(url)
            return note(.cancel, action: action, extra: ["reason": "external-move"])
        }

        return note(.allow, action: action)
    }

    /// What to do with one navigation response (headers are in).
    func decide(_ response: WKNavigationResponse) -> Decision {
        let http = response.response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""

        // `Content-Disposition: attachment` is the one header that means
        // "download this" rather than "display this".
        if disposition.contains("attachment") {
            return note(.download(.contentDispositionAttachment), response: response)
        }
        // A response the web view cannot render is a file, not a page. Without
        // this, tapping a `.zip` or an `.xlsx` in DSH lands on a blank document
        // and the app looks frozen.
        if !response.canShowMIMEType {
            return note(.download(.unshowableMIMEType), response: response)
        }
        return note(.allow, response: response)
    }

    // MARK: - New windows

    /// `WKUIDelegate`'s `createWebViewWithConfiguration:`.
    ///
    /// Returns nil for everything except a scripted popup with no URL of its
    /// own, because nil plus doing the work here is how a single-web-view app
    /// honours `target=_blank`: the caller still gets an answer, and the user
    /// still gets where they were going.
    func createWebView(
        configuration: WKWebViewConfiguration,
        action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = action.request.url
        let scheme = (url?.scheme ?? "").lowercased()

        // A popup that will set its own location (OAuth, print preview, a
        // library's report window). `about:blank` has no destination to send to
        // Safari, so this is the one case that needs a real web view.
        if url == nil || scheme == "about" {
            return presentPopup(configuration: configuration, action: action)
        }
        if let url, isOwnServer(url) {
            webView?.load(action.request)
            note(.cancel, action: action, extra: ["reason": "popup-local-in-place"])
            return nil
        }
        openExternally(url)
        note(.cancel, action: action, extra: ["reason": "popup-external"])
        return nil
    }

    private func presentPopup(
        configuration: WKWebViewConfiguration,
        action: WKNavigationAction
    ) -> WKWebView? {
        guard let presenter = ShareSheet.topViewController() else {
            note(.cancel, action: action, extra: ["reason": "popup-no-presenter"])
            return nil
        }
        let window = PopupWindow(configuration: configuration, router: self)
        popup = window
        window.present(from: presenter) { [weak self] in
            self?.popup = nil
        }
        note(.allow, action: action, extra: ["reason": "popup-created"])
        return window.webView
    }

    func notePopupClosed() {
        popup = nil
        record(["event": "popup-closed"])
    }

    // MARK: - JavaScript dialogs

    /// `alert`. The caller must not answer for the user: the completion handler
    /// is what tells WebKit the panel is gone, so it is called when the alert's
    /// button is pressed rather than the moment the alert is created. Calling it
    /// early leaves the native alert on screen after the page has already
    /// resumed — and, worse, makes "the dialog appeared" indistinguishable from
    /// "the user dismissed it".
    func presentAlert(message: String, completion: @escaping () -> Void) {
        record(["event": "dialog", "kind": "alert", "message": message])
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completion() })
        present(alert, completion: nil)
    }

    func presentConfirm(message: String, completion: @escaping (Bool) -> Void) {
        record(["event": "dialog", "kind": "confirm", "message": message])
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completion(true) })
        present(alert, completion: nil)
    }

    func presentPrompt(
        prompt: String,
        defaultText: String?,
        completion: @escaping (String?) -> Void
    ) {
        record(["event": "dialog", "kind": "prompt", "message": prompt, "default": defaultText ?? ""])
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completion(alert.textFields?.first?.text)
        })
        present(alert, completion: nil)
    }

    private func present(_ controller: UIAlertController, completion: (() -> Void)?) {
        guard let presenter = ShareSheet.topViewController() else { return }
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0
        )
        presenter.present(controller, animated: true, completion: completion)
    }

    // MARK: - URL classification

    /// Is this URL the DSH server this app is serving?
    ///
    /// Loopback by ADDRESS and, once the port is known, the same port the app's
    /// own DSH is listening on. Port equality is what separates "our UI" from
    /// "some other local server" (the guest channel, for one) — a page aimed at
    /// another loopback port is still not this app's UI and has no business
    /// replacing it.
    ///
    /// BEFORE the port is known the answer is YES for loopback. That is not
    /// sloppiness, it is the safe direction: `authenticatedURL` is nil only
    /// while DSH is still printing its URL, and answering "not ours" in that
    /// window would send the app's own first load to Safari and leave the app
    /// showing an empty web view.
    func isOwnServer(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
        guard loopback else { return false }
        guard let ownPort = NodeRunner.shared.authenticatedURL?.port else { return true }
        return url.port == ownPort || (url.port == nil && ownPort == 80)
    }

    /// Schemes worth handing to the system. A `javascript:` or `file:` URL in a
    /// link is not something to launch another app for.
    private func isLeavable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel", "sms", "facetime"].contains(scheme)
    }

    /// Every path that hands a URL to the system goes through here, so the
    /// scheme list is checked once for all of them. The new-window and popup
    /// branches used to call this without `isLeavable`, which let a page (or
    /// text a model wrote into it) launch any app with a registered scheme.
    private func openExternally(_ url: URL?) {
        guard let url else { return }
        guard isLeavable(url) else {
            record(["event": "external-blocked", "url": NodeRunner.redact(url.absoluteString),
                    "scheme": url.scheme?.lowercased() ?? ""])
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in
                self.record(["event": "external-open", "url": NodeRunner.redact(url.absoluteString),
                             "opened": opened])
            }
        }
    }

    // MARK: - Evidence

    @discardableResult
    private func note(
        _ decision: Decision,
        action: WKNavigationAction,
        extra: [String: Any] = [:]
    ) -> Decision {
        var event: [String: Any] = [
            "event": "action",
            "url": NodeRunner.redact(action.request.url?.absoluteString ?? "nil"),
            "targetFrame": action.targetFrame == nil ? "new-window" : (action.targetFrame!.isMainFrame ? "main" : "child"),
            "shouldPerformDownload": action.shouldPerformDownload,
        ]
        switch decision {
        case .allow: event["decision"] = "allow"
        case .cancel: event["decision"] = "cancel"
        case .download(let trigger): event["decision"] = "download"; event["trigger"] = trigger.rawValue
        }
        event.merge(extra) { _, new in new }
        record(event)
        return decision
    }

    @discardableResult
    private func note(_ decision: Decision, response: WKNavigationResponse) -> Decision {
        var event: [String: Any] = [
            "event": "response",
            "url": NodeRunner.redact(response.response.url?.absoluteString ?? "nil"),
            "mime": response.response.mimeType ?? "nil",
            "canShowMIMEType": response.canShowMIMEType,
            "isMainFrame": response.isForMainFrame,
            "disposition": (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition") ?? "nil",
        ]
        switch decision {
        case .allow: event["decision"] = "allow"
        case .cancel: event["decision"] = "cancel"
        case .download(let trigger): event["decision"] = "download"; event["trigger"] = trigger.rawValue
        }
        record(event)
        return decision
    }

    func record(_ event: [String: Any]) {
        guard LinkRouter.probeEnabled else { return }
        var payload = event
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        events.append(payload)
        flush()
    }

    private func flush() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["events": events], options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? data.write(to: documents.appendingPathComponent("DSHPortE-links.json"), options: .atomic)
    }
}

// MARK: - The popup web view

/// One modal web view for a `window.open` that has no URL yet.
///
/// Deliberately tiny: a web view, a title bar with a close button, and the same
/// routing rules as the main one. It is not a browser — it exists so that a
/// sign-in popup that sets its own location afterwards has somewhere to load.
@MainActor
final class PopupWindow: NSObject, WKNavigationDelegate {

    let webView: WKWebView
    private let router: LinkRouter
    private var onClose: (() -> Void)?
    private weak var controller: UIViewController?

    init(configuration: WKWebViewConfiguration, router: LinkRouter) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.router = router
        super.init()
        webView.navigationDelegate = self
        // The same shell tuning the main web view gets: a popup showing a login
        // form has the same zoom-on-focus problem.
        MobileWebTuning.configure(webView)
    }

    func present(from presenter: UIViewController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.modalPresentationStyle = .pageSheet
        webView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 44),
            webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        let title = UILabel()
        title.text = "窗口"
        title.font = .preferredFont(forTextStyle: .headline)
        title.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(title)
        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(close)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            title.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        self.controller = controller
        presenter.present(controller, animated: true)
    }

    @objc private func closeTapped() {
        dismiss()
    }

    func dismiss() {
        controller?.dismiss(animated: true)
        controller = nil
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        switch router.decide(navigationAction) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
            // A popup that has navigated to somewhere external is done: the
            // system browser has the request now and an empty sheet behind it
            // would just be something to close by hand.
            let url = navigationAction.request.url
            if let url, !router.isOwnServer(url), (url.scheme ?? "").lowercased() != "about" {
                dismiss()
            }
        case .download:
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        switch router.decide(navigationResponse) {
        case .allow: decisionHandler(.allow)
        case .cancel: decisionHandler(.cancel)
        case .download: decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        DownloadCoordinator.shared.adopt(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        DownloadCoordinator.shared.adopt(download)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A popup's popup: route it, do not stack sheets.
        _ = router.createWebView(
            configuration: configuration,
            action: navigationAction,
            windowFeatures: windowFeatures
        )
        return nil
    }
}
