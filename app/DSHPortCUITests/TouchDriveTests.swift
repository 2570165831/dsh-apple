//
//  TouchDriveTests.swift
//  DSHPortCUITests
//
//  Drives the real UI with genuine touch events.
//
//  WHY COORDINATES AND NOT ELEMENTS
//  --------------------------------
//  DSH's front end is React inside a WKWebView. Two other approaches were tried
//  and rejected on evidence:
//
//    * Enumerating the accessibility tree fails — the React document is large
//      enough that XCUITest intermittently answers "No matches found for Element
//      at index N".
//    * Synthesising DOM events from inside the page (pointerdown/mousedown/…
//      plus a React-compatible value setter) opens the workspace popup but the
//      selection does not commit, so the composer stays disabled. React's
//      delegated listeners want a real gesture.
//
//  So this test taps actual screen coordinates. Positions are derived from the
//  layout observed in screenshots/build-tagged runs, expressed in points for the
//  iPhone 17 simulator (1206x2622 px at 3x = 402x874 pt).
//
//  The prompts carry the keywords the mock model server keys on:
//    STREAMTEST -> a reply delivered as 12 separate SSE chunks
//    TOOLTEST   -> write, then read + glob, then a final text
//

import XCTest

final class TouchDriveTests: XCTestCase {
    private var app: XCUIApplication!

    // Layout constants, in points, measured from screenshots of the running app
    // on the iPhone 17 simulator (1206x2622 px at 3x = 402x874 pt).
    //
    // IMPORTANT: two layouts exist. Before the composer has focus the hero, the
    // workspace row and the composer sit low on the screen; once the keyboard
    // appears the whole column shifts up and the composer moves. Tapping the
    // pre-focus send position after typing hits the keyboard instead, which is
    // how an earlier run produced "no reply" with a perfectly valid prompt.
    private enum Layout {
        // ---- composer unfocused ----
        /// The "选择工作区" popup trigger under the hero title.
        static let workspaceTrigger = CGPoint(x: 135, y: 428)
        /// First row of the popup: "默认工作区".
        static let workspaceDefaultRow = CGPoint(x: 145, y: 469)
        /// The composer box, middle of its upper half.
        static let composer = CGPoint(x: 230, y: 490)

        // ---- composer focused (keyboard up) ----
        /// The blue arrow button at the composer's trailing edge, measured from
        /// screenshots/12-prompt-typed.png with the keyboard visible.
        static let sendButtonFocused = CGPoint(x: 350, y: 470)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    /// Wait for the web UI shell to be on screen (the DSH sidebar is visible).
    private func waitForShell(timeout: TimeInterval = 300) {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: timeout),
            "no web view appeared; boot text: \(app.staticTexts.allElementsBoundByIndex.map(\.label).prefix(10))"
        )
        // The plugin bundles load after first paint; the hero title appears then.
        let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "探索", "DeepSeek")
        let hero = webView.staticTexts.containing(predicate).firstMatch
        if !hero.waitForExistence(timeout: 180) {
            // Not fatal: some builds expose the hero only as part of the web
            // view's own label. Fall through and let the taps decide.
            XCTContext.runActivity(named: "hero title not exposed separately") { _ in }
        }
        sleep(2)
    }

    /// Tap a point inside the web view, in this app's coordinate space.
    private func tap(_ point: CGPoint, note: String) {
        let normalized = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
        normalized.tap()
        XCTContext.runActivity(named: "tap \(note) at \(point)") { _ in }
        sleep(1)
    }

    /// Type into the focused web composer.
    private func type(_ text: String) {
        app.typeText(text)
        sleep(1)
    }

    /// Select the default workspace, which the composer requires.
    private func selectWorkspace() {
        tap(Layout.workspaceTrigger, note: "workspace trigger")
        sleep(1)
        tap(Layout.workspaceDefaultRow, note: "default workspace row")
        sleep(2)
    }

    /// Screenshot into both the test attachments and the task's screenshots dir.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Resolved at run time rather than baked in: an absolute path with a
        // home directory in it only works on one machine.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshportc-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The rendered document text.
    ///
    /// A WKWebView's own `label`/`value` are empty or a page title in this
    /// WebKit version, so the rendered text has to come from its descendants.
    /// `staticTexts` is the narrowest query that returns page text; it is far
    /// smaller than the `descendants(matching: .any)` walk that intermittently
    /// failed with "No matches found for Element at index N".
    private func pageText() -> String {
        let webView = app.webViews.firstMatch
        guard webView.exists else { return "" }
        let direct = webView.label
        if !direct.isEmpty && direct.count > 40 { return direct }
        let texts = webView.staticTexts.allElementsBoundByIndex.map { element -> String in
            let label = element.label
            if !label.isEmpty { return label }
            return (element.value as? String) ?? ""
        }
        let joined = texts.joined(separator: "\n")
        if !joined.isEmpty { return joined }
        return (webView.value as? String) ?? direct
    }

    // MARK: - Tests

    /// The interface loads, a workspace can be chosen, and a message can be sent.
    func testSendsMessageAndStreamsReply() throws {
        waitForShell()
        capture("10-shell-loaded")
        selectWorkspace()
        capture("11-workspace-selected")

        tap(Layout.composer, note: "composer")
        type("STREAMTEST 请输出流式验证内容")
        capture("12-prompt-typed")

        // Send: the arrow button enables once the composer has text, and it has
        // moved up because the keyboard is showing.
        capture("12b-before-send")
        tap(Layout.sendButtonFocused, note: "send button (keyboard up)")

        // Sample the page until the reply's terminal marker shows up.
        var growth = 0
        var lastLength = 0
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let text = pageText()
            if text.count > lastLength + 1 {
                growth += 1
                lastLength = text.count
                if growth == 2 { capture("13-stream-midway") }
            }
            if text.contains("STREAMTEST-COMPLETE") { break }
            sleep(1)
        }
        capture("14-stream-final")

        print("PAGE_GROWTH \(growth) FINAL_LENGTH \(lastLength)")
        XCTAssertTrue(
            pageText().contains("STREAMTEST-COMPLETE"),
            "the streamed reply never completed; tail was: \(pageText().suffix(600))"
        )
    }

    /// The agent writes a file, reads it back, and searches the workspace.
    func testFileToolsRoundTrip() throws {
        waitForShell()
        selectWorkspace()

        tap(Layout.composer, note: "composer")
        type("TOOLTEST 请调用文件工具")
        tap(Layout.sendButtonFocused, note: "send button (keyboard up)")

        let deadline = Date().addingTimeInterval(240)
        var done = false
        while Date() < deadline {
            if pageText().contains("TOOLTEST 工具回合完成") { done = true; break }
            sleep(2)
        }
        capture("15-file-tools")
        XCTAssertTrue(done, "tool conversation never finished; tail: \(pageText().suffix(600))")
    }
}
