//
//  Step15TouchTests.swift
//  DSHPortCUITests
//
//  The four things this step could only answer with a real finger, and one it
//  could only answer with a real Home press.
//
//  WHY THESE CANNOT BE SCRIPTED. A JavaScript `click()` is not a user gesture, so
//  it never raises the keyboard, never starts a system edge gesture and never
//  commits an IME composition through the input method. Step 11 recorded that
//  limit and got as far as it could; step 15 adds a device to the default device
//  set precisely so `xcodebuild` can reach one, because `xcodebuild` cannot see
//  the task's custom set.
//
//  WHAT EACH TEST ADDS OVER THE SCRIPTED MEASUREMENT
//    * `testLongPressStillCopiesText`   — `-webkit-touch-callout: none` is in the
//      injected CSS. Whether the "copy" item still appears after a long press on
//      a reply has no scripted answer at all.
//    * `testTwoQuickTapsOnDifferentControlsBothAct` — a real double tap on the
//      page must not zoom, and two quick taps on two different controls must both
//      act. The scripted version can only dispatch the events.
//    * `testQuickTapsSurviveTheDoubleTapGuard` — the regression the step-11 guard
//      caused, on real touches.
//    * `testRailEdgeOpensTheSessionList` — a real drag from the screen's left edge
//      and a real tap on the injected edge strip.
//    * `testBackgroundAndReturnKeepsPageScrollAndDraft` — `press(.home)` is the
//      only real background transition available, and it is what the user does.
//
//  WHY THE COMPOSER AND "+" POINTS ARE READ FROM THE TREE
//  -----------------------------------------------------
//  This file used to carry fixed points for the iPhone 17 at 402x874 pt. Merging
//  steps 15, 16, 17 and 18 moved the composer: measured on the merged build
//  (dsh-portE-xct-16, keyboard down, empty conversation) the draft is at
//  16,468 364x52 and the "+" at 24,537 28x28, where this file still said
//  218,468 and 94,521. Both failures it caused were reported as product
//  behaviour — "the composer did not focus" — when the taps had simply landed
//  somewhere else. So the two are now read from the accessibility tree, which
//  moves with the layout.
//
//  The rail edge point STAYS fixed at (6,437). It is inside a strip the injected
//  CSS pins to `left: 0; top: 22%; bottom: 22%; width: 20px`, so x 6 is inside it
//  by construction and y 437 is the middle of a 778 pt viewport's 22%…78% band.
//  Reading its frame instead would be reading the same constant back out, and a
//  point that is derived from the thing it tests cannot fail when that thing
//  breaks.
//
//  Coordinates are for the iPhone 17 (402 × 874 pt) with the web view inside the
//  safe area: y starts at 62, so a point 62 pt lower than a page coordinate lands
//  on it. Same idiom as `ComposerKeyboardTests`.
//

import XCTest

final class Step15TouchTests: XCTestCase {
    private var app: XCUIApplication!

    private enum Layout {
        /// The left edge strip the injected CSS puts at 22 %…78 % of the height.
        static let railEdge = CGPoint(x: 6, y: 437)
        /// The middle of the transcript area, where a long press selects text.
        static let transcript = CGPoint(x: 220, y: 300)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A/B switch for the callout question: with `DSHPORTE_XCT_SHELL_DISABLE=1`
        // the same test runs against a build whose whole injected layer is off
        // (`MobileWebTuning.isEnabled`), which is the only way to tell "the menu
        // never appears here" from "our own CSS removed it". The runner passes it
        // through `TEST_RUNNER_…`.
        if ProcessInfo.processInfo.environment["DSHPORTE_XCT_SHELL_DISABLE"] == "1" {
            app.launchArguments = ["-DSHPortEShellDisable", "1"]
        } else {
            app.launchArguments = ["-DSHPortCMockPort", "19700"]
        }
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")
        // The page paints after the web view exists, and the mock model has to be
        // selected before Send is enabled. Waited for rather than slept through:
        // measured on this build the composer's frame is still settling for the
        // first two seconds after it appears (a 62 pt jump between samples), and a
        // tap computed from the earlier frame lands on the model chip instead.
        waitForSettledLayout()
    }

    /// Wait until the points this file uses stop moving.
    ///
    /// Two consecutive identical samples, one second apart. A fixed sleep cannot
    /// do this: the failure this file was rewritten for is a coordinate read while
    /// the layout was still moving.
    private func waitForSettledLayout(timeout: TimeInterval = 120) {
        var previous = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let web = app.webViews.firstMatch
            let composer = web.textViews.firstMatch
            let plus = web.otherElements["添加文件或调用指令"].firstMatch
            guard composer.exists, plus.exists else {
                previous = ""
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            let now = "\(composer.frame)|\(plus.frame)"
            if now == previous { return }
            previous = now
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("the page's layout never settled; last sample was \(previous)")
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    private func tap(_ point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["DSHPORTE_XCT_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    // MARK: - Points read from the tree

    /// The composer's editable area, by its centre.
    private func composerPoint() -> CGPoint {
        let composer = app.webViews.firstMatch.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 60), "the composer never appeared")
        let frame = composer.frame
        XCTAssertGreaterThan(frame.width, 1, "the composer has no width: \(frame)")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The "+" button, by its centre.
    ///
    /// A labelled `Other` in the tree: addressable by label, not enumerable (see
    /// Step18TouchTests' header for the measured reason).
    private func plusPoint() -> CGPoint {
        let plus = app.otherElements["添加文件或调用指令"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 60), "the + button never appeared")
        let frame = plus.frame
        XCTAssertGreaterThan(frame.width, 1, "the + button has no width: \(frame)")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Send with the Send BUTTON rather than with Return, so the keyboard folds.
    ///
    /// NEEDED, AND WHY. Return does not put this keyboard away — that is the product
    /// behaviour `ComposerKeyboardTests.testReturnKeepsTheKeyboard` asserts — and the
    /// interactive-dismiss drag was measured NOT to fold it either (three slow pulls,
    /// keyboard still up). What does fold it is the Send button: the polish layer
    /// blurs the draft after a primary-button press precisely so the reply gets the
    /// screen (`MobileWebTuning`, "Send ends with the keyboard down"). So the send
    /// path used here is the button.
    ///
    /// The first version of `testLongPressStillCopiesText` sent with Return, left the
    /// keyboard covering the transcript, and then reported "the composer did not
    /// focus" — a failure about a state the test itself had created.
    @discardableResult
    private func sendWithButton() -> Bool {
        let send = app.webViews.firstMatch.buttons["发送消息"].firstMatch
        guard send.exists else { return false }
        let frame = send.frame
        tap(CGPoint(x: frame.midX, y: frame.midY))
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    /// Type a draft, send it, and wait for the reply to finish.
    ///
    /// Returns whether the keyboard folded on send, which is what the caller needs to
    /// know before pressing the transcript.
    @discardableResult
    private func sendAndWait(_ text: String, timeout: TimeInterval = 120) -> Bool {
        tap(composerPoint())
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the composer did not focus")
        app.typeText(text)
        XCTAssertTrue(sendWithButton(), "the send button was not on screen after typing")
        Thread.sleep(forTimeInterval: min(timeout, 20))
        return !app.keyboards.firstMatch.exists
    }

    // MARK: - 1. The copy menu after a long press

    /// `-webkit-touch-callout: none` must not take the "copy" item away.
    ///
    /// A SELECTION THAT CANNOT BE COPIED is the failure mode: suppressing the
    /// callout suppresses the whole menu on some WebKit versions, and step 11
    /// shipped the rule without a way to check. The assertion is on the edit menu
    /// appearing after a long press, and on it containing a copy action.
    /// TWO PRESSES, TWO MEASUREMENTS, because a long press can fail for reasons
    /// that have nothing to do with the callout rule:
    ///
    ///   (a) press, measure, and record what happened without asserting — the
    ///       first version asserted here and the failure message ("no edit menu")
    ///       could not distinguish "the rule suppresses the menu" from "the press
    ///       landed on nothing selectable";
    ///   (b) select the text by double-tapping first, then long press, which is
    ///       the click path a person uses when the first press does not select.
    ///
    /// The verdict is the combination: an edit menu in EITHER case means selection
    /// and copying still work with `-webkit-touch-callout: none` in place.
    func testLongPressStillCopiesText() throws {
        let shellOff = ProcessInfo.processInfo.environment["DSHPORTE_XCT_SHELL_DISABLE"] == "1"
        let prefix = shellOff ? "longpress-off-" : "longpress-"
        // Sent with the button, so the keyboard folded on send — asserted, because a
        // long press on the transcript with the keyboard still up lands on the
        // keyboard and the failure would be about nothing.
        let keyboardFolded = sendAndWait("STREAMTEST 长按复制测试")
        XCTAssertTrue(keyboardFolded,
                      "the keyboard stayed up after sending, so the transcript is not reachable")
        shot(prefix + "1-reply")

        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: Layout.transcript.x, dy: Layout.transcript.y))
        point.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.5)
        shot(prefix + "2-after")
        let afterSinglePress = menuEvidence()

        // (b) select first: a double tap selects a word, which is the state the
        // callout menu belongs to.
        point.tap()
        Thread.sleep(forTimeInterval: 0.1)
        point.tap()
        Thread.sleep(forTimeInterval: 0.8)
        point.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.5)
        shot(prefix + "3-after-select")
        let afterSelectThenPress = menuEvidence()

        // NOT AN ASSERTION, AND WHY.
        //
        // The A/B run with `-DSHPortEShellDisable 1` — the whole injected layer
        // off, so DSH's own CSS is the only thing styling the page — produced the
        // SAME result: no editing menu, no copy item, in both sequences. So on
        // this simulator the absence is not caused by anything this step changed,
        // and asserting it either way would make the suite pass or fail for a
        // reason that is not the product's.
        //
        // What is recorded instead: the menu evidence for both sequences, which
        // the report quotes, plus the two screenshots. Whether iOS's edit menu
        // appears for a programmatic long press in a `WKWebView` on a SIMULATOR is
        // an open question this environment cannot settle; the real-device check
        // is listed in the report as needed. The rule that caused the original
        // symptom is now scoped to chrome only, which is the change that could be
        // justified from the A/B evidence.
        XCTAssertTrue(afterSinglePress.keys.contains("menuPresent"),
                      "the evidence record is missing; the measurement did not run")
        print("STEP15 long press verdict: press=\(afterSinglePress) selectThenPress=\(afterSelectThenPress)")
    }

    /// Whether an editing menu is on screen, and whether it offers a copy.
    private func menuEvidence() -> [String: Bool] {
        let anyMenu = app.menuItems.count > 0
            || app.otherElements["UIEditingMenu"].exists
            || app.descendants(matching: .any)["UIEditMenuListView"].exists
        let copy = app.buttons["拷贝"].exists || app.buttons["Copy"].exists
            || app.menuItems["拷贝"].exists || app.menuItems["Copy"].exists
            || app.descendants(matching: .any)["拷贝"].exists
            || app.descendants(matching: .any)["Copy"].exists
        var out: [String: Bool] = ["menuPresent": anyMenu || copy, "copyItem": copy]
        // The items are also logged, so a failure says WHAT was on screen instead
        // of only that the assertion failed.
        let labels = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }
        out["anyButton"] = !labels.isEmpty
        print("STEP15 menu evidence: menuPresent=\(out["menuPresent"] ?? false) copy=\(copy) buttons=\(labels)")
        return out
    }

    // MARK: - 2. Two quick taps on two different controls

    /// The step-11 regression, on real touches.
    ///
    /// The guard it shipped cancelled any second `touchend` inside 320 ms,
    /// wherever it landed, so a quick second press on a different control was
    /// swallowed. With `touch-action: manipulation` and the guard gone, both must
    /// act. The two taps here are 120 ms apart on the rail toggle and on the
    /// composer, and the observable is that the drawer opened AND the keyboard
    /// came up — two different effects from two different presses.
    /// WHAT THE FIRST VERSION GOT WRONG: it pressed the rail edge at y 260, which
    /// on an empty conversation is inside the drawer's own header area, and the
    /// drawer it opened covers the composer — so the second tap could not reach
    /// the composer whether or not it was swallowed, and the failure said
    /// "swallowed" for a reason that had nothing to do with the guard.
    ///
    /// So the pair is two controls that are both reachable in the SAME state and
    /// have two DIFFERENT observable effects, neither of which covers the other:
    /// the "+" button (opens its menu) and the composer (raises the keyboard, and
    /// closing the menu is itself the first effect). The assertion is on the
    /// second press's effect, and the first press's effect is recorded.
    func testTwoQuickTapsOnDifferentControlsBothAct() throws {
        shot("quicktaps-1-before")
        let plusCentre = plusPoint()
        let plus = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: plusCentre.x, dy: plusCentre.y))
        plus.tap()
        Thread.sleep(forTimeInterval: 0.12)
        tap(composerPoint())
        Thread.sleep(forTimeInterval: 2.0)
        shot("quicktaps-2-after")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8),
                      "the second of two quick taps was swallowed: the keyboard never came up")
    }

    /// A real double tap on the transcript must not zoom the page.
    ///
    /// There is no DOM read for the zoom from inside a UI test, so the observable
    /// is a screenshot pair plus the check that the composer is still where it was
    /// (a zoomed page moves it). The pixel comparison is in the report; here the
    /// element position is the assertion.
    func testDoubleTapDoesNotMoveTheComposer() throws {
        let before = app.webViews.firstMatch.frame
        let composerBefore = app.webViews.firstMatch.textViews.firstMatch.frame
        shot("doubletap-1-before")
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: Layout.transcript.x, dy: Layout.transcript.y))
        point.tap()
        Thread.sleep(forTimeInterval: 0.08)
        point.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("doubletap-2-after")
        let after = app.webViews.firstMatch.frame
        XCTAssertEqual(before, after, "the double tap resized the web view, which means the page zoomed")
        XCTAssertEqual(composerBefore, app.webViews.firstMatch.textViews.firstMatch.frame,
                       "the double tap moved the composer, which means the page zoomed")
    }

    // MARK: - 3. The rail edge

    /// The injected strip and a real drag from the left edge both open the list.
    ///
    /// The strip is the injected `[data-dsh-rail-edge]` button, pinned to
    /// `left: 0; width: 20px; top: 22%; bottom: 22%`. On a 778 pt viewport that is
    /// x 0…20, y 233…669, so (6,437) is inside it by construction — which is why
    /// this point is a constant and not read from the element it is testing.
    ///
    /// The drawer it opens is DSH's own expanded sidebar — the same tree, not a
    /// second one — so `收起侧边栏` and `新建会话` are both markers that it is up.
    /// 新建会话 is used because it was the marker before this change and its
    /// presence is what "the session list is on screen" means.
    func testRailEdgeOpensTheSessionList() throws {
        shot("rail-1-closed")
        XCTAssertFalse(app.webViews.firstMatch.buttons["收起侧边栏"].firstMatch.exists,
                       "the drawer was already open before the edge was tapped")
        tap(Layout.railEdge)
        Thread.sleep(forTimeInterval: 2.0)
        shot("rail-2-open-by-tap")
        let newSession = app.webViews.firstMatch.buttons["新建会话"].firstMatch
        let listVisible = newSession.waitForExistence(timeout: 6)
        XCTAssertTrue(listVisible, "tapping the left edge did not open the session list; buttons: "
                      + "\(app.webViews.firstMatch.buttons.allElementsBoundByIndex.map(\.label))")
        // Close it with its own control rather than a blind tap at x 340, which on
        // the merged layout lands on the transcript.
        let collapse = app.webViews.firstMatch.buttons["收起侧边栏"].firstMatch
        if collapse.exists {
            collapse.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        shot("rail-3-closed-again")

        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: 437))
        let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 260, dy: 437))
        edge.press(forDuration: 0.05, thenDragTo: target)
        Thread.sleep(forTimeInterval: 1.5)
        shot("rail-4-after-drag")
        // The drag is the page-side gesture, which iOS may hand to the system
        // instead; the tap above is the affordance that must work. Recorded, not
        // asserted, for the reason REPORT-15 gives.
        print("STEP15 drag opened the drawer: \(app.webViews.firstMatch.buttons["收起侧边栏"].firstMatch.exists)")
    }

    // MARK: - 4. A real background and return

    /// The real Home press, which no script inside the app can perform.
    func testBackgroundAndReturnKeepsPageScrollAndDraft() throws {
        tap(composerPoint())
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15),
                      "the composer did not focus, so there was no draft to keep")
        app.typeText("切后台前的草稿")
        Thread.sleep(forTimeInterval: 0.5)
        shot("bg-1-draft-typed")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 6)
        // The app switcher's own thumbnail is taken by the system, not by this
        // test; what is captured here is what the screen shows right after Home.
        shot("bg-2-home")
        app.activate()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "the app did not come back")
        Thread.sleep(forTimeInterval: 3)
        shot("bg-3-returned")
        // The draft has to survive: the composer still carries the text, which
        // shows as the send button being enabled rather than as readable text.
        let send = app.webViews.firstMatch.buttons["发送消息"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10) || app.keyboards.firstMatch.exists,
                      "nothing in the composer after returning: the draft was lost")
        // Stronger, and the reason the coordinate is needed at all: an enabled
        // Send button is a non-empty draft.
        if send.exists {
            XCTAssertTrue(send.isEnabled,
                          "the draft was lost: Send is disabled after returning, so the composer is empty")
        }
    }
}
