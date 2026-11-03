//
//  DSHPortCUITests.swift
//  DSHPortCUITests
//
//  Drives the real app: launches it, waits for the DSH web UI, creates a
//  session, sends a scripted prompt, and observes the reply growing on screen.
//
//  This is the only honest way to claim "the interface works". Everything it
//  asserts is something a person would also see; nothing here reaches into the
//  app's own files or calls its internal APIs.
//
//  The mock model server must be running on the host (scripts/mock-start.sh).
//  The prompts carry the keywords the mock keys its scripts on:
//    STREAMTEST  -> a reply delivered in 12 separate SSE chunks
//    TOOLTEST    -> a three-turn tool conversation (write, then read + glob)
//

import XCTest

final class DSHPortCUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    /// The web view's rendered text, as WebKit exposes it to accessibility.
    ///
    /// Only the web view's own label is read. Enumerating descendants is
    /// deliberately avoided: the React document is large enough that XCUITest
    /// intermittently fails the snapshot with "No matches found for Element at
    /// index N". See TouchDriveTests for the coordinate-based approach.
    private func webText() -> String {
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 5) else { return "" }
        let label = webView.label
        if !label.isEmpty { return label }
        return (webView.value as? String) ?? ""
    }

    private func waitForUI(timeout: TimeInterval = 240) throws {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: timeout),
            "the DSH web view never appeared; boot screen said: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        // The plugin bundles finish loading after `didFinish`; give them time
        // before asserting on rendered content.
        sleep(5)
    }

    /// Type into the DSH composer and send.
    private func sendPrompt(_ text: String) throws {
        let composer = app.webViews.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer not found")
        composer.tap()
        composer.typeText(text)

        // Prefer the labelled send button; fall back to the Return key.
        let send = app.webViews.buttons["发送消息"]
        if send.waitForExistence(timeout: 5) {
            send.tap()
        } else {
            composer.typeText("\n")
        }
    }

    // MARK: - Tests

    /// The UI comes up and shows DSH's own chrome.
    func testWebInterfaceLoads() throws {
        try waitForUI()
        let strings = webText()
        XCTAssertTrue(
            strings.contains("探索未至之境") || strings.contains("DeepSeek") || strings.contains("工作区"),
            "expected DSH chrome, saw: \(strings.prefix(600))"
        )
        attachScreenshot(named: "01-ui-loaded")
    }

    /// A scripted reply arrives in pieces, so the visible text grows over time.
    ///
    /// The assertion is deliberately about *multiple observations of growth*: a
    /// buffered transport would produce exactly one jump.
    func testStreamingReplyIsIncremental() throws {
        try waitForUI()
        try sendPrompt("STREAMTEST 请输出流式验证内容")

        var samples: [(TimeInterval, Int)] = []
        let start = Date()
        var lastLength = 0
        var growthCount = 0

        // 30 seconds at 500ms: DSH re-renders as deltas land.
        while Date().timeIntervalSince(start) < 30 {
            let length = webText().count
            samples.append((Date().timeIntervalSince(start), length))
            if length > lastLength + 1 {
                growthCount += 1
                lastLength = length
                if growthCount == 3 { attachScreenshot(named: "02-stream-midway") }
            }
            if webText().contains("STREAMTEST-COMPLETE") { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attachScreenshot(named: "03-stream-final")

        let summary = samples.map { String(format: "%.1fs:%d", $0.0, $0.1) }.joined(separator: " ")
        print("STREAM_SAMPLES \(summary)")
        print("STREAM_GROWTH_COUNT \(growthCount)")

        XCTAssertGreaterThanOrEqual(
            growthCount, 3,
            "expected the reply to grow at least 3 times as deltas streamed; samples: \(summary)"
        )
        XCTAssertTrue(
            webText().contains("STREAMTEST-COMPLETE"),
            "streamed reply never completed; samples: \(summary)"
        )
    }

    /// The agent writes a file, reads it back, and searches the workspace.
    func testFileToolsRoundTrip() throws {
        try waitForUI()
        try sendPrompt("TOOLTEST 请调用文件工具")

        let deadline = Date().addingTimeInterval(120)
        var sawFinal = false
        while Date() < deadline {
            let text = webText()
            if text.contains("TOOLTEST 工具回合完成") {
                sawFinal = true
                break
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        attachScreenshot(named: "04-file-tools")

        XCTAssertTrue(sawFinal, "the tool conversation never produced its final text; page text was: \(webText().suffix(800))")
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also write a plain PNG next to the test result so the report can embed
        // it without unpacking an .xcresult bundle.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshportc-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
