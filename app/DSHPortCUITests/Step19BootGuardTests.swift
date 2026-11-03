//
//  Step19BootGuardTests.swift
//  DSHPortCUITests
//
//  Step 19's buttons, pressed. The acceptance script drives the guard with launch
//  arguments and reads files, so it says nothing about whether the failure screen,
//  the safe-mode banner and the reset panel do what they say when touched.
//
//  One test on purpose: each stage starts from the state the previous one left,
//  and the run assumes a fresh install so the first reset panel has no
//  `boot/reset-plan.json` to read.
//

import XCTest

final class Step19BootGuardTests: XCTestCase {
    private var app: XCUIApplication!
    private let mockArgs = ["-DSHPortCMockPort", "19719"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String] = []) {
        app.terminate()
        app.launchArguments = mockArgs + extra
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func requireTap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) never appeared")
        element.tap()
    }

    /// Scroll a form until the element is on screen.
    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "\(element) is not in the panel")
    }

    private func shareSheetAppears() -> Bool {
        app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
            || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2)
    }

    /// On this runtime the sheet is a popover even on a phone, so it is closed by
    /// its dismiss region, and the assertion is that it really went away.
    private func closeShareSheet() {
        let region = app.otherElements["PopoverDismissRegion"].firstMatch
        if region.waitForExistence(timeout: 3) {
            region.tap()
            XCTAssertTrue(region.waitForNonExistence(timeout: 5), "the share sheet did not close")
        } else {
            requireTap(app.buttons["Close"].firstMatch, "the share sheet's close button")
        }
    }

    private func openDebugEntry(_ label: String) {
        launch(["-DSHPortEShowDebugMenu", "1"])
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 120), "the page never came up")
        XCTAssertTrue(app.sheets["调试"].firstMatch.waitForExistence(timeout: 60), "no debug menu")
        requireTap(app.buttons[label].firstMatch, "debug entry \(label)")
    }

    /// Leaves one exported bundle on disk from each path, for the runner script to
    /// read: this runner has no way into the app's container.
    func testExportLeavesBundles() throws {
        launch(["-DSHPortEBootFailFast", "1"])
        requireTap(element("bootDiagnosticsButton"), "the export button")
        XCTAssertTrue(shareSheetAppears(), "no share sheet from the failure screen")
        closeShareSheet()
        openDebugEntry("导出诊断包")
        XCTAssertTrue(shareSheetAppears(), "no share sheet from a healthy launch")
        closeShareSheet()
    }

    func testButtons() throws {
        // Stage 1: three failed launches, and the failure screen they end on.
        for _ in 0..<3 {
            launch(["-DSHPortEBootFailFast", "1"])
            XCTAssertTrue(element("bootResetButton").waitForExistence(timeout: 30), "no failure screen")
        }
        let reason = element("bootDetail")
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertTrue(reason.label.contains("DSHPortEBootFailFast"), "reason on screen: \(reason.label)")
        shot("01-failure-screen")

        // The reason is still the real one after the page watchdog's minute.
        Thread.sleep(forTimeInterval: 65)
        XCTAssertTrue(element("bootDetail").label.contains("DSHPortEBootFailFast"),
                      "the watchdog replaced the reason: \(element("bootDetail").label)")
        shot("02-failure-screen-after-65s")

        requireTap(element("bootLogButton"), "the log button")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "dshportc")).firstMatch
            .waitForExistence(timeout: 10), "the log sheet shows no log")
        shot("03-failure-log")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(element("bootDiagnosticsButton").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)

        // Node never started on this launch, so this is the local package.
        requireTap(element("bootDiagnosticsButton"), "the export button")
        XCTAssertTrue(shareSheetAppears(), "no share sheet from the failure screen")
        shot("04-failure-share")
        closeShareSheet()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "最小诊断包")).firstMatch
            .waitForExistence(timeout: 5), "the screen does not say what was exported")
        shot("05-failure-after-share")

        requireTap(element("bootResetButton"), "the reset button")
        XCTAssertTrue(element("resetKeepConversations").waitForExistence(timeout: 10), "no reset panel")
        shot("06-reset-panel-from-failure")
        let builtin = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "App 内置")).firstMatch
        scrollTo(builtin)
        shot("07-reset-panel-builtin-note")
        requireTap(app.buttons["取消"].firstMatch, "the panel's cancel")

        // Stage 2: the fourth launch is safe mode, and the banner says so.
        launch()
        // By label: the banner's own identifier replaces its children's in the tree.
        let banner = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "安全模式")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 120), "no safe-mode banner")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60))
        shot("08-safe-mode")
        requireTap(app.buttons["重置运行环境"].firstMatch, "the banner's reset")
        XCTAssertTrue(element("resetKeepConversations").waitForExistence(timeout: 10))
        shot("09-reset-panel-from-safe-mode")
        requireTap(app.buttons["取消"].firstMatch, "the panel's cancel")

        // Stage 3: leaving safe mode from the banner, in the launch that shows it.
        // The launch after a good safe-mode launch probes a normal start by itself.
        requireTap(app.buttons["退出安全模式"].firstMatch, "the exit button")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "the app did not quit")
        app.launchArguments = mockArgs
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 120))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(banner.exists, "still in safe mode after leaving it")
        shot("10-after-exit-safe-mode")

        // Stage 4: the export button on a healthy launch. Node is up, so the answer
        // has to come from it and not from the local package.
        openDebugEntry("导出诊断包")
        XCTAssertTrue(shareSheetAppears(), "no share sheet from a healthy launch")
        shot("11-healthy-share")
        closeShareSheet()
        Thread.sleep(forTimeInterval: 1)
        shot("12-healthy-after-share")

        // Stage 5: a real reset through the panel, keeping what it keeps by default.
        openDebugEntry("重置运行环境")
        let start = element("resetConfirm")
        XCTAssertTrue(element("resetKeepConversations").waitForExistence(timeout: 10))
        scrollTo(start)
        shot("13-reset-panel-bottom")
        start.tap()
        requireTap(app.buttons["重置并退出"].firstMatch, "the reset confirmation")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "the app did not quit for the reset")
        app.launchArguments = mockArgs
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "no page after the reset")
        shot("14-after-reset")

        // Stage 6: what the reset left behind can be removed, and only on request.
        openDebugEntry("重置运行环境")
        let purge = element("resetPurgeStaging")
        XCTAssertTrue(element("resetKeepConversations").waitForExistence(timeout: 10))
        scrollTo(purge)
        XCTAssertTrue(purge.isEnabled, "nothing to purge after a reset")
        shot("15-purge-before")
        purge.tap()
        let confirm = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "删除")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no purge confirmation")
        shot("16-purge-confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已清除")).firstMatch
            .waitForExistence(timeout: 10), "no purge result")
        shot("17-purge-after")
    }
}
