//
//  ContentView.swift
//  DSHPortC
//
//  The whole user-visible surface: the DSH web UI, plus a thin shell that says
//  what the embedded Node is doing while it boots and offers the boot log when
//  something fails.
//
//  The web view is the product. The chrome around it exists because an embedded
//  Node takes a while to come up on a phone, and a blank screen with no
//  explanation is not an acceptable first launch.
//

import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var model = BootViewModel()
    @State private var showingLog = false
    @State private var showingGuestConsole = false
    @State private var showingDebugMenu = false
    /// The scheme the page itself is painting, mirrored from DSH's own theme
    /// service. `nil` until the page has said; the native bands then follow the
    /// iOS appearance, which is right for the launch and boot screens.
    @State private var pageScheme: String?
    @State private var showingNotificationSettings = false
    @State private var showingReset = false
    /// The one-line result of the last diagnostics export, shown on the failure
    /// screen. A share sheet that the user dismissed is not an error, so this is
    /// a sentence rather than an alert.
    @State private var diagnosticsStatus = ""
    /// The view the iPad share popover points at.
    @State private var shareAnchor = ShareAnchor()
    /// Whether the splash's mark has faded in. Set on first appear and never
    /// cleared, so the fade runs once per launch rather than on every redraw.
    @State private var markVisible = false
    @ObservedObject private var padProbe = PadProbe.shared

    var body: some View {
        // NO NavigationStack AND NO TOOLBAR IN THE NORMAL PATH.
        //
        // Step 11's third finding: a navigation bar plus a toolbar of four items
        // (a runtime badge, a terminal button, a box button and a reload button)
        // cost 116 pt of a 874 pt screen — 13 % of the display, permanently, for
        // controls a phone user touches about never. Worse, the bar is applied to
        // the content, so the first message starts below it and the reading area
        // is that much shorter for the whole session.
        //
        // So the chrome is gone and the web view fills the safe area. The three
        // things the bar reached are still reachable:
        //   * a two-finger long press anywhere on the page opens a debug menu;
        //   * the boot log has its own entry in that menu, so a failed launch
        //     still explains itself without the bar;
        //   * the same three items are in the menu as `accessibilityIdentifier`
        //     buttons, so the existing UI tests keep working.
        //
        // STEP 21: THE SWAP FROM THE SPLASH TO THE PAGE IS A CROSS-FADE.
        //
        // The two branches live inside one `ZStack` so they can overlap for the
        // duration of the transition: `if/else` alone removes the splash before
        // the page is inserted, and the frame between them is whatever is behind
        // — which is the white flash the task reports. With the `.background`
        // below painting the same colour on both, and the fade running in front
        // of it, no frame of a different colour can appear. `opacity` is animated
        // both ways (out on the splash, in on the page) with the same curve, so
        // the sum stays at 1 and neither side ever shows a gap.
        // STEP 19 FIX: the splash is no longer the `else` of the page. It used to
        // be, so the moment Node printed a URL the splash — and with it the
        // failure screen's three buttons — was gone, and a page that then never
        // painted left a blank web view for good (measured: 75 s into a held
        // load, `boot-outcome.json` said "页面在 60 秒内没有就绪" and the screen
        // was empty). Now the splash sits ON TOP of the web view until the page
        // has painted, so a failure after the URL still lands on it.
        ZStack {
            if model.readyURL != nil {
                    DSHWebView(
                        url: model.readyURL!,
                        anchor: shareAnchor,
                        reloadGeneration: model.reloadGeneration,
                        onDebugGesture: { showingDebugMenu = true },
                        onLoadStart: { model.noteWebViewLoading() },
                        onReady: {
                            model.noteWebViewReady()
                            // Step 21: cross-fade the page in over the splash.
                            model.notePagePainted()
                            // Step 16: a notification tapped while the app was
                            // killed remembers its session id until there is a
                            // page to navigate; this is the moment there is one.
                            NotificationBridge.shared.pageDidBecomeReady()
                            // Test-only hook: see UIDriver. No-op unless the app
                            // was launched with -DSHPortCTestDrive 1.
                            if UIDriver.isEnabled {
                                Task { @MainActor in UIDriver.shared.runScriptedPromptIfConfigured() }
                            }
                            // Step 10's iPad sweep. No-op unless launched with
                            // -DSHPortEPadProbe 1.
                            PadProbe.shared.sweep(label: "webview-ready")
                            PadProbe.shared.attemptRotationIfConfigured()
                            // Whether a session row can be pressed open, when one
                            // is on screen at all. Also probe-gated.
                            PadProbe.shared.pressFirstSessionRowIfConfigured()
                            PadProbe.shared.runKeyboardProbeIfConfigured()
                            // Step 11's interaction measurements. No-op unless
                            // launched with -DSHPortEStep11 1.
                            InteractionProbe.shared.runIfConfigured()
                            // Step 15's sweep: the six checks step 11 left, the
                            // rail, and the three send modes. No-op unless
                            // launched with -DSHPortEStep15 1.
                            Step15Probe.shared.runIfConfigured()
                            // Step 17's download / link / dialog cases. No-op
                            // unless launched with -DSHPortEShareCase <name>.
                            ShareProbe.shared.runIfConfigured()
                            // Step 17's guest/workspace file cases. No-op unless
                            // launched with -DSHPortEFilesProbe <case>.
                            FilesProbe.shared.runIfConfigured()
                        },
                        onFailure: { message in model.noteWebViewFailure(message) },
                        onPageScheme: { scheme in pageScheme = scheme }
                    )
                    // NO `ignoresSafeArea`. The web view stays inside the safe area
                    // on every edge, and the page colour fills what is around it
                    // (`.background` below).
                    //
                    // Top: DSH's CSS has no `env(safe-area-inset-*)` anywhere, so a
                    // page under the status bar draws the conversation title on top
                    // of the clock. Step 11's first version did exactly that.
                    //
                    // Bottom: the default safe area includes the keyboard, and that
                    // is the keyboard fix. `ignoresSafeArea(edges:)` with no
                    // `regions:` means `.all`, which ignores the keyboard too: the
                    // web view kept its full height with the composer behind the
                    // keyboard (measured: `innerHeight` 874, `visualViewport.height`
                    // 477, composer at y 438…490). Left alone, the web view shrinks
                    // to the space above the keyboard, `innerHeight` follows and DSH
                    // relayouts. With the keyboard down it also keeps the composer's
                    // status line clear of the home indicator.
                    //
                    // Split View stand-in. `nil` (the normal case) leaves the
                    // layout untouched; a fraction narrows the web view and lets
                    // SwiftUI centre it, which is the part of Split View that
                    // DSH's own layout store reacts to. PadProbe's comment says
                    // what this does NOT reproduce. Observed, not read once: the
                    // staged sweep changes it while the app runs, and the change
                    // has to reach the web view or the sweep measures nothing.
                    .padLayoutFraction(padProbe.fraction ?? PadProbe.commandLineFraction)
                    // The page fades IN over the splash. `opacity` on the page
                    // rather than a `.transition` on the branch, because a
                    // transition would remove one side before inserting the other.
                    .opacity(model.pageVisible ? 1 : 0)
            }
            bootScreen
                .opacity(model.pageVisible ? 0 : 1)
                .allowsHitTesting(!model.pageVisible)
                .accessibilityHidden(model.pageVisible)
            }
            .animation(.easeInOut(duration: 0.34), value: model.pageVisible)
            // What shows around the web view: the status bar band, the home
            // indicator band and the sensor-side margin in landscape.
            //
            // The colour follows the PAGE, not just the system appearance. DSH
            // has its own theme preference and can disagree with iOS — a page
            // fixed to light on a phone in dark mode is the case that made the
            // dark bands obvious. `pageScheme` is what the page reported through
            // DSH's own `data-ds-theme-source`, so the two cannot drift.
            .background(Color(MobileWebTuning.Palette.pageBackground(forPageScheme: pageScheme)).ignoresSafeArea())
            // STEP 19: the safe-mode banner. An overlay at the top rather than a
            // band that shrinks the page: the page is the product, and a launch in
            // safe mode is the launch where its layout must not also change. The
            // two buttons are the two things a person wants from that screen — get
            // back to a normal launch, or start over.
            .overlay(alignment: .top) {
                if model.safeMode.active {
                    safeModeBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: model.safeMode.active)
            .sheet(isPresented: $showingLog) {
                LogView(text: model.logText)
            }
            .sheet(isPresented: $showingReset) {
                ResetSheet(containerRoot: ResetRunner.containerRoot)
            }
            .sheet(isPresented: $showingGuestConsole) {
                GuestConsoleView()
            }
            .sheet(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
            }
            // A launch-argument way to open the same menu, for the UI test that
            // proves the entries are still reachable. Without it the only way in
            // is a real two-finger long press, which XCUITest cannot perform.
            .onAppear {
                if UserDefaults.standard.integer(forKey: "DSHPortEShowDebugMenu") == 1 {
                    showingDebugMenu = true
                }
                // Opens the boot log directly, for the UI check that the entry in
                // the menu actually presents the sheet. Two separate flags because
                // they answer two separate questions: "is the menu there" and
                // "does its first entry do something".
                if UserDefaults.standard.integer(forKey: "DSHPortEShowBootLog") == 1 {
                    showingLog = true
                }
                // Opens the notification switch sheet directly, for the screenshot of
                // the sheet and for the UI check that the menu entry presents it —
                // the same reason the two flags above exist. A normal launch never
                // passes it.
                if UserDefaults.standard.integer(forKey: "DSHPortEShowNotifySettings") == 1 {
                    showingNotificationSettings = true
                }
            }
            // The debug menu the long press opens, and the same three entries the
            // old toolbar had. `confirmationDialog` rather than a `Menu` because
            // a dialog's buttons are individually addressable by XCUITest, and the
            // existing UI tests look them up by identifier.
            .confirmationDialog("调试", isPresented: $showingDebugMenu, titleVisibility: .visible) {
                Button("启动日志") { showingLog = true }
                    .accessibilityIdentifier("bootLogButton")
                Button("Linux 控制台") { showingGuestConsole = true }
                    .accessibilityIdentifier("guestConsoleButton")
                Button("重新加载界面") { model.reloadWebView() }
                    .accessibilityIdentifier("reloadButton")
                // Step 16: the way to the four notification switches. A dialog
                // entry because the sheet has no other entry point — the toolbar
                // this menu replaced is gone (step 11) and there is no settings
                // surface of the app's own. It is also what puts the switches
                // "in the debug menu (two-finger long press)" as the task asks.
                Button("通知设置") { showingNotificationSettings = true }
                    .accessibilityIdentifier("notifySettingsButton")
                // Step 19. Reachable from a HEALTHY launch too, not only from the
                // failure screen: "export a bundle" is what someone does when the
                // app works but misbehaves, and "reset" is what they look for
                // before they would otherwise delete the app.
                Button("导出诊断包") { exportDiagnostics() }
                    .accessibilityIdentifier("diagnosticsButton")
                Button("重置运行环境") { showingReset = true }
                    .accessibilityIdentifier("resetButton")
                Button("取消", role: .cancel) { }
            } message: {
                Text(model.statusBadge.isEmpty ? "DSH" : model.statusBadge)
                    .accessibilityIdentifier("runtimeBadge")
            }
        .onAppear {
            // Step 15's launch-screen sampling has to start BEFORE the page
            // exists: the boot screen is gone by the time any page-side probe can
            // run. No-op unless launched with `-DSHPortEStep15 1 -...Action boot`.
            Step15Probe.shared.scheduleBootSamples()
            model.start()
            // Step 13: subscribe to the background/foreground transitions so a
            // running turn can ask iOS to keep going after the app is hidden.
            // One line, no state of its own in this view: everything it needs is
            // in BackgroundContinuation, which keeps this file mergeable while
            // step 11 rewrites it.
            BackgroundContinuation.shared.start()
            // Step 16: install the notification delegate and watch the scene, so a
            // turn that ends while the user is in another app can be announced.
            // One line, for the same merge reason as the line above.
            NotificationBridge.shared.start()
            // No-op unless the app was launched with -DSHPortEGuestTest 1. The
            // guest acceptance run lives behind this, so a normal launch is
            // untouched.
            GuestSelfTest.shared.runIfConfigured()
            // Step 4B device measurements; no-op without -DSHPortEProbe 1.
            DeviceProbe.shared.runIfConfigured()
        }
    }

    /// The safe-mode banner: what it is, what it turned off, and the two ways out.
    ///
    /// Deliberately narrow (a strip at the top, not a screen) and dismissible only
    /// by acting on it. A user in safe mode has a working app with some plugins
    /// off; covering the page with an explanation would trade one problem for
    /// another. The subtitle carries the guard's own words, so "why am I in safe
    /// mode" is answerable without opening a log.
    private var safeModeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("安全模式：已跳过 \(model.safeMode.skipped.count) 个插件")
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("safeModeHeadline")
                Spacer(minLength: 0)
            }
            if !model.safeMode.reason.isEmpty {
                Text(model.safeMode.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("safeModeReason")
            }
            HStack(spacing: 10) {
                Button("退出安全模式") { model.exitSafeMode() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("exitSafeModeButton")
                Button("重置运行环境") { showingReset = true }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("safeModeResetButton")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
        .accessibilityIdentifier("safeModeBanner")
    }

    /// Export a diagnostics bundle and remember the one-line result.
    ///
    /// A free function on the view rather than a `BootViewModel` method because it
    /// needs the popover anchor, which is a UIKit view this view owns; the
    /// `BootViewModel` is deliberately free of view concerns.
    private func exportDiagnostics() {
        diagnosticsStatus = "正在导出诊断包…"
        DiagnosticsShare.export(anchor: shareAnchor.view) { status in
            diagnosticsStatus = status
        }
    }

    /// The launch experience: the app's own icon, fading in, and gone the moment
    /// the page has painted.
    ///
    /// WHAT THIS REPLACED AND WHY. Until step 21 the first screen was a large
    /// `ProgressView` over two lines of small text ("正在启动内嵌 Node" / "App
    /// 进程内的 Node 24 正在加载 DSH") plus, on a slow launch, a monospaced block
    /// of node/v8/modules facts and a "查看启动日志" button. That is a diagnostic
    /// panel, not a splash screen: it tells the user about an implementation they
    /// did not ask about, and the spinner does not resolve into anything.
    ///
    /// The task asks for three things and this view is all three:
    ///
    ///   1. `LaunchMark` — the app icon's own mark, from the asset catalogue, so
    ///      the splash and the home-screen icon are the same drawing rather than
    ///      two designs that nearly match. It fades in on appear.
    ///   2. A cross-fade into the page instead of a cut. `ContentView` swaps this
    ///      view for the web view when `readyURL` arrives; the transition is on
    ///      that branch (see `body`), and both sides are painted on the same
    ///      background colour, so no frame of a different colour can appear
    ///      between them. That is what "转进网页时不闪白" needs: not a longer
    ///      animation, but the absence of a white frame underneath it.
    ///   3. NO diagnostic text on the normal path. The two lines that remain are
    ///      the ones that answer "what is it doing" in plain language, and they
    ///      appear only after the launch has taken noticeably longer than usual —
    ///      see `model.isSlowLaunch`. The log entry is NOT on this screen — the
    ///      task says it should appear only when the launch has timed out — and it
    ///      is on the failure screen instead, which is the state where it exists
    ///      for a reason.
    private var bootScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // 128 pt, not 104: the mark's own artwork leaves ~28 % padding on each
            // side inside its 240 pt canvas (see `scripts/make-app-icon.py`), so a
            // 104 pt frame draws a ~60 pt glyph. Measured on the captured splash:
            // the blue strokes covered about 1.5 % of a 760 px square around the
            // centre, which is a small mark on a large white field. 128 pt makes the
            // glyph read as the app's icon at arm's length without changing the
            // artwork.
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .accessibilityIdentifier("bootMark")
                .accessibilityLabel("DSH")
                // The fade IN. 0.28 s is long enough to read as a fade and short
                // enough that it is over before the page could have appeared; the
                // launch is 4.5–6 s, so this costs no measurable start-up time —
                // it runs while Node is booting, not before it.
                .opacity(markVisible ? 1 : 0)
                .scaleEffect(markVisible ? 1 : 0.94)
                .animation(.easeOut(duration: 0.28), value: markVisible)
            // The slow-launch (and failure) explanation. Reserved (an empty band)
            // rather than conditionally inserted, so crossing the threshold does
            // not make the mark jump.
            Group {
                if model.isSlowLaunch || model.bootFailed {
                    VStack(spacing: 6) {
                        Text(model.headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("bootHeadline")
                        Text(model.detail)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 32)
                            .accessibilityIdentifier("bootDetail")
                    }
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 56, alignment: .top)
            .padding(.top, 22)
            // The log entry, and ONLY when the launch has actually gone wrong.
            //
            // The task's wording is "日志入口平时不显示，只有启动超时才出现". A
            // failed launch is the case that matters more than a slow one: the mark
            // is still on screen, nothing is happening, and this is the only place
            // the reason can be read. So both the slow path and the failed path
            // show it, and the normal path shows nothing.
            // STEP 19: a failed launch offers three things, and they are the
            // three answers to "the app will not start": read the reason, export
            // it so someone else can look, or start over. Before this step the
            // screen offered only the log, and the only real way out — deleting
            // the app, taking every conversation with it — was not on it at all.
            if model.bootFailed {
                HStack(spacing: 12) {
                    Button("查看启动日志") { showingLog = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("bootLogButton")
                    Button("导出诊断包") { exportDiagnostics() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("bootDiagnosticsButton")
                }
                .padding(.top, 18)
                Button("重置运行环境") { showingReset = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("bootResetButton")
                    .padding(.top, 10)
                if !diagnosticsStatus.isEmpty {
                    Text(diagnosticsStatus)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                        .accessibilityIdentifier("bootDiagnosticsStatus")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { markVisible = true }
    }
}

/// A weak holder for the web view, so the share sheet has a popover anchor.
///
/// `ShareSheet.present` needs a `UIView` on iPad — a popover without a source
/// view raises `NSGenericException` and the app dies (see its header). SwiftUI has
/// no way to hand a `UIView` to a `@State` in a value type, so this small class
/// holds the view weakly and the state holds an instance of it.
final class ShareAnchor {
    weak var view: UIView?
}

/// Thin wrapper so SwiftUI can recreate the configuration cleanly on reload.
struct DSHWebView: UIViewRepresentable {
    let url: URL
    /// Receives the created web view so the share sheet can anchor to it.
    var anchor: ShareAnchor? = nil
    /// Bumped by the debug menu's reload entry; a change reloads the page.
    let reloadGeneration: Int
    let onDebugGesture: () -> Void
    let onLoadStart: () -> Void
    let onReady: () -> Void
    let onFailure: (String) -> Void
    /// The scheme the page itself is painting, when it changes.
    ///
    /// The native bands around the web view have to agree with the page, and the
    /// page's answer is DSH's own theme preference, which need not match the iOS
    /// appearance. `MobileWebTuning` polls for it and this carries the answer out
    /// to the SwiftUI colour.
    let onPageScheme: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            url: url,
            reloadGeneration: reloadGeneration,
            onDebugGesture: onDebugGesture,
            onLoadStart: onLoadStart,
            onReady: onReady,
            onFailure: onFailure,
            onPageScheme: onPageScheme
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // The UI is same-origin loopback over plain HTTP, so nothing needs to be
        // relaxed here beyond what Info.plist already allows for localhost.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Test-only diagnostics. A failing RPC on this page is otherwise
        // invisible: the composer simply stays disabled and the only clue is a
        // toast that has already faded. The hook is installed only when the test
        // driver is enabled, so a normal launch runs the page exactly as built.
        if UIDriver.isEnabled {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: UIDriver.diagnosticsBootstrapScript(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        // Step 10's keystroke recorder. Same gating idea as the diagnostics hook
        // above: only a probe launch installs it, so a normal launch runs the
        // page exactly as built. It has to be at document start, because the
        // question it answers is which chords reach the page at all.
        if PadProbe.isEnabled {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: PadProbe.recorderBootstrapScript(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        // What a phone needs the page to do differently. At document start,
        // because the viewport meta has to exist before the first layout.
        if MobileWebTuning.isEnabled {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: MobileWebTuning.bootstrapScript(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        // Step 18's per-screen polish: hit areas, hover-only controls, the status
        // line, and the one-column settings dialog. Its own style element, its own
        // switch, so it can be measured and reverted without step 11's layer.
        if !MobileWebPolish.isDisabled {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: MobileWebPolish.bootstrapScript(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.accessibilityIdentifier = "dshWebView"
        // Opaque is what `MobileWebTuning.configure` needs: it sets both the
        // view's own colour and the under-page colour, so the rubber band shows
        // the app's background rather than the system's white.
        webView.isOpaque = true
        MobileWebTuning.configure(webView)
        MobileWebTuning.removeInputAccessoryFromContentViews(webView)
        // Mirror the page's own theme into the native bands. The stop closure is
        // dropped on purpose: this web view lives as long as the view does, and a
        // timer that fires against a replaced web view is harmless (the
        // `evaluateJavaScript` completion simply never runs).
        _ = MobileWebTuning.watchPageTheme(webView) { scheme in
            context.coordinator.reportPageScheme(scheme)
        }
        MobileWebPolish.configure(webView)  // step 18; one native setting
        context.coordinator.attach(webView)
        // Step 19: the popover anchor for the diagnostics share sheet. Weak, so a
        // replaced web view is not kept alive by it.
        anchor?.view = webView
        // The way into the debug menu. Two fingers, because a one-finger long press
        // on this page already means something: it selects text, and a menu opening
        // part way through a selection is what step 11's first version would have
        // done. Nothing else here uses two fingers, since pinch zoom is off
        // (MobileWebTuning).
        let debugPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDebugPress(_:))
        )
        debugPress.numberOfTouchesRequired = 2
        debugPress.minimumPressDuration = 0.8
        debugPress.allowableMovement = 24
        debugPress.cancelsTouchesInView = false
        debugPress.delegate = context.coordinator
        webView.addGestureRecognizer(debugPress)
        UIDriver.shared.register(webView)
        PadProbe.shared.register(webView)
        InteractionProbe.shared.register(webView)
        Step15Probe.shared.register(webView)
        // Step 17: the download/share and link/dialog paths need the view they
        // act on. Both are no-ops without their probe arguments.
        ShareProbe.shared.register(webView)
        Step18Probe.shared.register(webView)  // step 18; no-op without its flag
        // Step 16: the notification bridge navigates a tapped notification into a
        // session by pressing the same sidebar row a finger would, so it needs this
        // web view. Registered unconditionally — unlike the probes above, this is the
        // feature itself, not a measurement.
        NotificationNavigation.shared.register(webView)
        // The host-side acceptance drives one named action through this same view
        // (answer an approval, press stop, read the selection). Only a launch that
        // names an action reaches it; a normal launch runs the page as built.
        NotificationActionDriver.shared.register(webView)
        // Every launch mints a new `dsh-auth-*` cookie and the old ones are never
        // removed; past ~70 of them the request header exceeds Node's limit and
        // the server answers 431, which is a blank page. Sweep first, then load,
        // and let the 303 that answers this launch's token set the fresh cookie.
        MobileWebTuning.sweepStaleAuthCookies(store: configuration.websiteDataStore) { removed in
            InteractionProbe.shared.noteNavigation("cookie-sweep", ["removed": removed])
            context.coordinator.load()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            context.coordinator.load()
        }
        if context.coordinator.reloadGeneration != reloadGeneration {
            context.coordinator.reloadGeneration = reloadGeneration
            context.coordinator.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        var currentURL: URL
        var reloadGeneration: Int
        private let onDebugGesture: () -> Void
        private let onLoadStart: () -> Void
        private let onReady: () -> Void
        private let onFailure: (String) -> Void
        private let onPageScheme: (String?) -> Void
        private weak var webView: WKWebView?
        private var readyReported = false
        /// The last scheme the page reported, so a poll that finds nothing new
        /// does not redraw the whole view tree every second.
        private var reportedScheme: String?

        init(
            url: URL,
            reloadGeneration: Int,
            onDebugGesture: @escaping () -> Void,
            onLoadStart: @escaping () -> Void,
            onReady: @escaping () -> Void,
            onFailure: @escaping (String) -> Void,
            onPageScheme: @escaping (String?) -> Void
        ) {
            currentURL = url
            self.reloadGeneration = reloadGeneration
            self.onDebugGesture = onDebugGesture
            self.onLoadStart = onLoadStart
            self.onReady = onReady
            self.onFailure = onFailure
            self.onPageScheme = onPageScheme
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            // Step 17's two seams: downloads need an anchor for the iPad share
            // popover, and the link/dialog rules need the view they act on.
            DownloadCoordinator.shared.anchorView = webView
            LinkRouter.shared.webView = webView
        }

        /// Publish the page's scheme, once per real change.
        func reportPageScheme(_ scheme: String?) {
            guard scheme != reportedScheme else { return }
            reportedScheme = scheme
            onPageScheme(scheme)
        }

        func load() {
            guard let webView else { return }
            readyReported = false
            onLoadStart()
            webView.load(URLRequest(url: currentURL))
        }

        /// Reload what is on screen. The launch URL's token has already been
        /// exchanged for a cookie, so the page's own URL is the one to repeat; only
        /// a page that never loaded has to go back to the launch URL.
        func reload() {
            guard let webView else { return }
            guard webView.url != nil else { load(); return }
            readyReported = false
            onLoadStart()
            webView.reload()
        }

        @objc func handleDebugPress(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { onDebugGesture() }
        }

        /// The press must not take touches away from the page's own recognizers.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadStart()
            InteractionProbe.shared.noteNavigation("didStartProvisional", ["url": NodeRunner.redact(webView.url?.absoluteString ?? "nil")])
        }

        /// The redirect chain, recorded only under the step-11 probe.
        ///
        /// DSH's web server answers the token URL with 303 + Set-Cookie and a
        /// relative `Location: ./`; whether WebKit followed that hop is the one
        /// fact a DOM probe cannot see, and it is exactly where an empty document
        /// comes from.
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            InteractionProbe.shared.noteNavigation("serverRedirect", ["to": NodeRunner.redact(webView.url?.absoluteString ?? "nil")])
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let response = navigationResponse.response as? HTTPURLResponse {
                InteractionProbe.shared.noteNavigation("response", [
                    "status": response.statusCode,
                    "url": NodeRunner.redact(response.url?.absoluteString ?? "nil"),
                    "location": response.value(forHTTPHeaderField: "Location") ?? "nil",
                    "setCookie": response.value(forHTTPHeaderField: "Set-Cookie") == nil ? "absent" : "present",
                    "isMainFrame": navigationResponse.isForMainFrame,
                    "mime": response.mimeType ?? "nil",
                    "expectedLength": response.expectedContentLength,
                ])
            }
            // Step 17: `Content-Disposition: attachment` and MIME types the web
            // view cannot render become downloads instead of blank documents.
            // The rule itself lives in LinkRouter; this is the wiring only.
            switch LinkRouter.shared.decide(navigationResponse) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .download(let trigger):
                DownloadCoordinator.shared.noteTrigger(trigger)
                decisionHandler(.download)
            }
        }

        /// Step 17: every navigation action is classified by `LinkRouter` — a
        /// download, an external link that leaves for the system browser, a
        /// "new window" that stays in place, or an ordinary page load.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            switch LinkRouter.shared.decide(navigationAction) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .download(let trigger):
                DownloadCoordinator.shared.noteTrigger(trigger)
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            DownloadCoordinator.shared.adopt(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            DownloadCoordinator.shared.adopt(download)
        }

        // MARK: - WKUIDelegate (step 17; the rules live in LinkRouter)

        /// A `target=_blank` or `window.open`. Returning nil cancels WebKit's
        /// own new-window path, which is the point: `LinkRouter` has already
        /// decided where the request goes, and a second web view would be a
        /// second DSH session nobody asked for.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            LinkRouter.shared.createWebView(
                configuration: configuration,
                action: navigationAction,
                windowFeatures: windowFeatures
            )
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            LinkRouter.shared.presentAlert(message: message, completion: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            LinkRouter.shared.presentConfirm(message: message, completion: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            LinkRouter.shared.presentPrompt(
                prompt: prompt,
                defaultText: defaultText,
                completion: completionHandler
            )
        }

        /// Re-apply the accessory suppression when the composer takes focus.
        ///
        /// WebKit rebuilds the content view (and with it the form assistant) when
        /// the page is reloaded or the web process is relaunched, so a one-shot
        /// swap at creation is not enough. Re-applying on focus is cheap and
        /// idempotent — an already-swapped view is skipped.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MobileWebTuning.removeInputAccessoryFromContentViews(webView)
            // `didFinish` fires when the document and its synchronous resources
            // are in, which is what "the UI is up" means for this app. The React
            // tree finishes its own hydration a moment later; the readiness flag
            // is checked separately so the number in the report is about the
            // web view, not about DSH's hydration.
            if !readyReported {
                readyReported = true
                // STEP 19B's way to reproduce "the page never becomes ready", which
                // PLAN-19 §11 item 7 left open. Blocking the loopback port or
                // pointing the web view at a dead one reproduces a DIFFERENT failure
                // (`didFailProvisionalNavigation`, a web-view error), not this one:
                // the page has to load and then simply never be declared ready.
                // Waiting here does exactly that, and it is gated on a launch
                // argument so a normal launch cannot reach it.
                let holdMs = UserDefaults.standard.integer(forKey: "DSHPortEStep19HoldReadyMs")
                if holdMs > 0 {
                    NodeRunner.shared.emit(
                        "dshportc: TEST holding the page-ready signal for \(holdMs) ms (page painted)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(holdMs)) { [weak self] in
                        NodeRunner.shared.emit("dshportc: TEST releasing the page-ready signal")
                        self?.onReady()
                    }
                    return
                }
                onReady()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            // A cancelled navigation is the normal result of a reload; not a failure.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            onFailure("webview: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        }
    }
}

/// Plain scrollable log. Token redaction already happened on the way in.
struct LogView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var refreshToken = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(空)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("启动日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .id(refreshToken)
    }
}

/// Bridges the non-SwiftUI runner into observable state.
@MainActor
final class BootViewModel: ObservableObject {
    @Published var readyURL: URL?
    @Published var headline = "正在启动内嵌 Node"
    @Published var detail = "App 进程内的 Node 24 正在加载 DSH"
    @Published var logText = ""
    @Published var runtimeFacts: String?
    @Published var reloadGeneration = 0
    /// Whether the page is the visible layer. Drives the cross-fade out of the
    /// splash (step 21); set a frame after `readyURL` so the swap animates instead
    /// of cutting.
    @Published var pageVisible = false
    /// Whether the launch has taken long enough to be worth explaining.
    ///
    /// WHAT THIS IS FOR. The splash shows only the mark, because on a normal
    /// launch there is nothing to explain and the app is up in under six seconds.
    /// A launch that is still going after `slowLaunchAfter` is a different
    /// situation, and silently showing a mark for twenty seconds is what makes
    /// people think the app has hung. So the two status lines appear at that point
    /// — and only then.
    ///
    /// MEASURED, NOT GUESSED: step 21's cold starts on this device were 4.57 /
    /// 4.74 / 5.72 s (median 4.74). Eight seconds is comfortably past all three,
    /// so the normal path never shows text.
    @Published private(set) var isSlowLaunch = false
    /// Whether the launch has failed. The one other state that is worth a sentence
    /// and a way into the log.
    @Published private(set) var bootFailed = false
    /// Step 19: the safe-mode decision, mirrored out of the runner's status so the
    /// banner does not have to poll a non-observable object itself.
    @Published private(set) var safeMode = SafeModeReport()
    private static let slowLaunchAfter: TimeInterval = 8.0
    private var slowLaunchTimer: Timer?

    private let runner = NodeRunner.shared
    private var started = false
    private var pollTimer: Timer?

    var navigationTitle: String {
        readyURL == nil ? "DSH · 启动中" : "DSH"
    }

    var statusBadge: String {
        let node = runner.status.node
        guard !node.nodeVersion.isEmpty else { return "" }
        return "Node \(node.nodeVersion)"
    }

    func start() {
        guard !started else { return }
        started = true
        logText = runner.existingLog()

        runner.onLog { line in
            Task { @MainActor in
                self.logText += line + "\n"
                if self.logText.count > 200_000 {
                    self.logText = String(self.logText.suffix(150_000))
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .dshServerReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor in
                self?.readyURL = url
                self?.headline = "正在加载界面"
                self?.detail = "Node 已就绪，WebView 正在连本机端口"
            }
        }

        runner.begin()
        startPolling()
        // The explanation timer. Fires once; if the page is already up by then it
        // does nothing, and it is cancelled the moment the page appears.
        slowLaunchTimer = Timer.scheduledTimer(withTimeInterval: Self.slowLaunchAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.readyURL == nil || !self.pageVisible else { return }
                self.isSlowLaunch = true
            }
        }
    }

    /// The page has painted: fade it in over the splash.
    ///
    /// Called from the web view's `onReady`, which fires on `didFinish`. The one
    /// frame of delay matters: SwiftUI needs the page to have been laid out once
    /// before an opacity change on it can animate, otherwise the first frame of
    /// the fade shows an unlaid-out web view — a grey rectangle, which is the same
    /// class of flash the fade exists to remove.
    func notePagePainted() {
        slowLaunchTimer?.invalidate()
        slowLaunchTimer = nil
        guard !pageVisible else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pageVisible = true
        }
    }

    /// Mirror the runner's phase into the two lines of text on the boot screen.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let status = NodeRunner.shared.status
                if let facts = self.formatFacts(status.node) { self.runtimeFacts = facts }
                // Step 19: one assignment per poll, and only when it changed, so
                // the banner's animation is driven by a real transition rather
                // than by a 5 Hz rewrite of the same value.
                let reported = status.safeMode ?? SafeModeReport()
                if reported.active != self.safeMode.active
                    || reported.mode != self.safeMode.mode
                    || reported.skipped != self.safeMode.skipped
                    || reported.reason != self.safeMode.reason {
                    self.safeMode = reported
                }
                // Step 15's launch measurement reads what THIS screen is showing,
                // not what the view hierarchy happens to expose. No-op unless the
                // probe is enabled with the `boot` action.
                Step15Probe.shared.noteBootScreen(headline: self.headline,
                                                  detail: self.detail,
                                                  runtimeFacts: self.runtimeFacts)
                switch status.phase {
                case BootPhase.failed.rawValue:
                    self.headline = "启动失败"
                    self.detail = status.error ?? status.detail
                    // Step 21: a failed launch is worth a sentence and a way into
                    // the log. This is what replaced the splash screen's permanent
                    // "查看启动日志" button — the entry is on screen when there is
                    // something to read, and not before.
                    self.bootFailed = true
                    self.isSlowLaunch = true
                case BootPhase.nodeRunning.rawValue:
                    self.headline = "Node 已启动，正在加载 DSH"
                    self.detail = status.detail
                case BootPhase.serverListening.rawValue, BootPhase.webViewLoading.rawValue:
                    self.headline = "正在加载界面"
                    self.detail = status.detail
                default:
                    break
                }
            }
        }
    }

    private func formatFacts(_ node: NodeReport) -> String? {
        guard !node.nodeVersion.isEmpty else { return nil }
        var lines = [
            "node \(node.nodeVersion)  v8 \(node.v8Version)  modules \(node.moduleVersion)",
            "webassembly: \(node.webAssembly)  jitless: \(node.jitless)",
        ]
        if node.childProcessBlocked { lines.append("child_process: blocked") }
        if node.addonLoadingBlocked { lines.append("addon loading: blocked") }
        return lines.joined(separator: "\n")
    }

    /// Ask the next launch to run the normal composition, then quit.
    ///
    /// The user pressing this button IS the statement "try a normal launch now",
    /// which is why `boot-guard.mjs` honours it without waiting for another three
    /// failures (`OWN_REQUESTS`). `exit(0)` because the profile and the plugin
    /// tree are decided before `node_start`; there is nothing to re-decide in a
    /// live process.
    func exitSafeMode() {
        guard BootGuard.request("exit-safe-mode") else {
            detail = "无法写入退出安全模式的请求"
            return
        }
        detail = "已请求退出安全模式，请重新打开 App"
        exit(0)
    }

    func noteWebViewLoading() { runner.noteWebViewLoading() }
    func noteWebViewReady() { runner.noteWebViewReady() }
    func noteWebViewFailure(_ message: String) { runner.noteFailure(message) }
    func reloadWebView() { reloadGeneration += 1 }
    func load(url: URL) { readyURL = url }
}
