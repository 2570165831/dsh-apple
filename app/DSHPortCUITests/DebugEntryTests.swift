//
//  DebugEntryTests.swift
//  DSHPortCUITests
//
//  The debug entries are still reachable after step 11 removed the toolbar.
//
//  WHY THIS TEST EXISTS
//  --------------------
//  Step 11 took the navigation bar and its four toolbar items off the screen, and
//  moved the three things they reached (boot log, Linux console, reload) into a
//  menu opened by a two-finger long press. That is a claim about the UI with a
//  real way to be wrong: the buttons could be present in code and unreachable by a
//  person. The only honest check is to open the menu the way the app opens it and
//  read what appears.
//
//  The menu is opened here by a launch argument because XCUITest has no two-finger
//  press (`press(forDuration:)` is one finger, `twoFingerTap()` has no duration).
//  The launch argument drives the same state variable the gesture drives, so what
//  is asserted — "the three entries are on screen and the log opens" — is the part
//  that would actually break.
//

import XCTest

final class DebugEntryTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    /// The three entries the old toolbar had are all in the menu, and the first
    /// one opens the boot log.
    ///
    /// WHY THE LOOKUP IS BY LABEL AND NOT BY IDENTIFIER
    /// -----------------------------------------------
    /// `ContentView.swift:141` opens this menu from a launch argument
    /// (`DSHPortEShowDebugMenu`), and the entries carry
    /// `accessibilityIdentifier("bootLogButton")` and friends. The merge did not
    /// change any of that — measured, the dialog IS on screen after the argument
    /// (a `Sheet` labelled `调试` with four buttons at 97,150 · 97,206 · 97,262 ·
    /// 97,318), and it appeared within a second of the web view existing.
    ///
    /// What changed is that the identifiers do not survive into the accessibility
    /// tree on this runtime. The dialog's `Sheet` subtree reports NO identifiers at
    /// all: the only two `identifier:` values in the whole dump are `dshWebView`
    /// and the popover's `PopoverDismissRegion`. So `app.buttons["bootLogButton"]`
    /// does not exist, and the previous version waited the full 60 s for it and then
    /// hit a snapshot failure while trying to list what was there instead.
    ///
    /// That is not a product regression: the buttons are on screen, reachable, and
    /// their labels are the ones the code sets (`启动日志`, `Linux 控制台`,
    /// `重新加载界面`, `通知设置`). SwiftUI's `confirmationDialog` mirrors a
    /// button's label into accessibility and drops the identifier here. So the
    /// lookups now go by label, with the identifier tried first so a runtime that
    /// does surface it keeps using it.
    func testDebugMenuReachesBootLog() throws {
        app.launchArguments = ["-DSHPortEShowDebugMenu", "1"]
        app.launch()

        // The page has to be up: the menu is attached to the web view's container,
        // and the boot screen has its own separate entry.
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300),
                      "the web view never appeared")

        // The dialog, by its own title. Waiting for the dialog rather than for one
        // of its buttons keeps the two failures apart: "the menu never opened" and
        // "the menu opened without that entry".
        let dialog = app.sheets["调试"].firstMatch
        let dialogAppeared = dialog.waitForExistence(timeout: 60)
        if !dialogAppeared {
            print("DEBUG-MENU tree:\n\(app.debugDescription.prefix(6000))")
        }
        XCTAssertTrue(dialogAppeared, "the debug menu never appeared after -DSHPortEShowDebugMenu 1")
        print("DEBUG-MENU entries=\(app.buttons.allElementsBoundByIndex.map { "\($0.label)#\($0.identifier)" })")

        let logButton = debugEntry(identifier: "bootLogButton", label: "启动日志")
        XCTAssertTrue(logButton.exists,
                      "no boot-log entry in the debug menu; entries on screen: "
                          + "\(app.buttons.allElementsBoundByIndex.map(\.label))")

        // The other two entries are present too, which is what "the toolbar's
        // three things are still reachable" means.
        XCTAssertTrue(debugEntry(identifier: "guestConsoleButton", label: "Linux 控制台").exists,
                      "no Linux-console entry in the debug menu")
        XCTAssertTrue(debugEntry(identifier: "reloadButton", label: "重新加载界面").exists,
                      "no reload entry in the debug menu")

        logButton.tap()

        // The log sheet says its own title once it is up; that is the evidence the
        // entry does something rather than just existing.
        let title = app.navigationBars["启动日志"]
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "tapping 启动日志 did not open the log sheet")
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the log sheet has no 完成 button")
        done.tap()
    }

    /// A debug-menu entry, by identifier when the runtime carries it and by label
    /// when it does not. See the test above for the measurement.
    private func debugEntry(identifier: String, label: String) -> XCUIElement {
        let byIdentifier = app.buttons[identifier]
        if byIdentifier.exists { return byIdentifier }
        return app.buttons[label]
    }

    /// A normal launch has no chrome: the web view fills the safe area and stays
    /// out from under the status bar.
    ///
    /// This is the other half of the same change, and it is what the task asked
    /// for by name ("让 DSH 网页占满（注意安全区，内容不能钻进状态栏或灵动岛下面）").
    /// DSH's CSS does not read the safe-area insets, so the web view's own frame is
    /// the only thing keeping the page's title off the clock.
    func testNormalLaunchHasNoChromeAndStaysInsideTheSafeArea() throws {
        app.launch()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 300), "the web view never appeared")

        XCTAssertFalse(app.navigationBars["DSH"].exists, "a navigation bar titled DSH is still on screen")
        XCTAssertFalse(app.buttons["runtimeBadge"].exists, "the Node badge is still on screen")

        // Below the status bar, and still most of the window: the bar this replaced
        // left the page 87 % of it, so anything under that means chrome came back.
        let window = app.windows.firstMatch.frame
        let frame = webView.frame
        XCTAssertGreaterThanOrEqual(frame.minY, window.minY + 20,
                                    "the web view starts under the status bar: \(frame) vs \(window)")
        XCTAssertGreaterThan(frame.height, window.height * 0.87,
                             "the web view is shorter than the bar it replaced left it: \(frame) vs \(window)")
    }
}
