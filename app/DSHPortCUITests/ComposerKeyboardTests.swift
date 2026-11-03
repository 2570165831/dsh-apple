//
//  ComposerKeyboardTests.swift
//  DSHPortCUITests
//
//  A tap on the composer's toolbar does not raise the keyboard.
//
//  Only real touches can answer this. A script's `click()` is not a user gesture,
//  so it never raises the keyboard with or without the bug. Coordinates rather than
//  elements for the reason in TouchDriveTests: the accessibility tree of the React
//  document is unreliable.
//
//  WHY THE POINTS ARE DERIVED AND NOT WRITTEN DOWN
//  ----------------------------------------------
//  The first version of this file carried fixed points measured on an earlier
//  layout ("send at 358,533"). Merging steps 15, 16, 17 and 18 moved the composer
//  — the left edge strip now pushes the page, the composer card grew, the hero's
//  spacing changed — and every one of the five tests failed for the same reason
//  that has nothing to do with the keyboard: the taps landed somewhere else.
//  Measured on the merged build (dsh-portE-xct-16, 402x874 pt, keyboard down,
//  empty conversation): composer text view 16,468 364x52; "+" 24,537 28x28;
//  send 342,532 34x34; and with the keyboard up the send button is 342,384.
//
//  So the send and "+" points are READ FROM THE TREE at run time
//  (`app.buttons["发送消息"].frame`), and the draft point is the composer text
//  view's own centre. Nothing here assumes a y coordinate, so the next layout
//  change moves them with it instead of failing the way this file just did. The
//  one point that stays fixed is the blank area above the hero, which asserts its
//  own premise: it must be a place with nothing interactive on it.
//
//  Screenshots go to $DSHPORTE_XCT_SHOTS when it is set. Pass it to xcodebuild as
//  TEST_RUNNER_DSHPORTE_XCT_SHOTS.
//

import XCTest

final class ComposerKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-DSHPortCMockPort", "19700"]
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")
        // The page paints after the web view exists, and the mock model has to be
        // selected before Send is enabled. Waited for rather than slept through:
        // measured, the composer's frame is still settling for the first two
        // seconds after it first appears (a 62 pt jump between samples), and a tap
        // computed from the earlier frame lands in the wrong place — which is
        // exactly how the first version of this file failed after the merge.
        waitForSettledLayout()
    }

    /// Wait until every point this file uses stops moving.
    ///
    /// Two consecutive identical samples, one second apart. A fixed sleep cannot
    /// do this: the whole failure this file was rewritten for is a coordinate read
    /// while the layout was still moving.
    private func waitForSettledLayout() {
        var previous = ""
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let now = layoutSignature()
            if !now.isEmpty, now == previous { return }
            previous = now
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("the page's layout never settled; last signature was \(previous)")
    }

    /// The frames of the three controls the tests touch, as one comparable string.
    private func layoutSignature() -> String {
        let web = app.webViews.firstMatch
        let composer = web.textViews.firstMatch
        let send = web.buttons["发送消息"].firstMatch
        let plus = web.otherElements["添加文件或调用指令"].firstMatch
        guard composer.exists, send.exists, plus.exists else { return "" }
        return "\(composer.frame)|\(send.frame)|\(plus.frame)"
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

    private var keyboardIsUp: Bool { app.keyboards.firstMatch.exists }

    /// Wait out the keyboard's animation, then say whether it is on screen.
    private func keyboardSettled() -> Bool {
        Thread.sleep(forTimeInterval: 1.5)
        return keyboardIsUp
    }

    // MARK: - Points read from the tree

    /// The composer's editable area, by its centre.
    ///
    /// A `TextView` in the tree, not a coordinate: its frame is what moved.
    private func composerPoint() -> CGPoint {
        let composer = app.webViews.firstMatch.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 60), "the composer never appeared")
        let frame = composer.frame
        XCTAssertGreaterThan(frame.width, 1, "the composer has no width: \(frame)")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The send button, by its centre, in whatever state the keyboard is in.
    ///
    /// This is the point the reported bug is about, so it must be the button the
    /// page actually draws. `发送消息` is the accessibility label; its reported
    /// frame is the painted 34x34 the polish layer leaves alone (it is already
    /// past the hit-target minimum).
    private func sendPoint() -> CGPoint {
        let send = app.webViews.firstMatch.buttons["发送消息"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the send button never appeared")
        let frame = send.frame
        XCTAssertGreaterThan(frame.width, 1, "the send button has no width: \(frame)")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The "+" button, by its centre.
    ///
    /// It exposes as a labelled `Other`, which is addressable by label but not
    /// enumerable (see Step18TouchTests' header for the measured reason).
    private func plusPoint() -> CGPoint {
        let plus = app.otherElements["添加文件或调用指令"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 60), "the + button never appeared")
        let frame = plus.frame
        XCTAssertGreaterThan(frame.width, 1, "the + button has no width: \(frame)")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A point with nothing interactive under it: between the page's top bar and
    /// the hero title.
    ///
    /// DERIVED, NOT WRITTEN DOWN, for the same reason the other points are: the
    /// first version used a fixed (230,200), and on the merged build the hero
    /// title sits at y 188 — so the "blank" tap landed on the title. The point is
    /// now 40 pt above the title's top edge, and the assertion below checks the
    /// premise rather than restating the formula: it must not fall inside any
    /// control the tests touch.
    private func blankPoint() -> CGPoint {
        let web = app.webViews.firstMatch
        let title = web.staticTexts["探索未至之境"].firstMatch
        XCTAssertTrue(title.exists, "the hero title is not on screen, so there is no anchor for the blank point")
        let titleFrame = title.frame
        let webFrame = web.frame
        let point = CGPoint(x: 230, y: titleFrame.minY - 40)
        XCTAssertGreaterThan(point.y, webFrame.minY,
                             "the blank probe at \(point) is above the web view at \(webFrame)")

        // The premise, checked: nothing this file taps may contain the point, and
        // neither may the title itself.
        XCTAssertFalse(titleFrame.contains(point),
                       "the blank probe at \(point) is inside the hero title at \(titleFrame)")
        for (name, centre) in [("composer", composerPoint()), ("send", sendPoint()), ("+", plusPoint())] {
            // A 44 pt square around each control's centre: the hit region the
            // polish layer gives it, not just its painted box.
            let region = CGRect(x: centre.x - 22, y: centre.y - 22, width: 44, height: 44)
            XCTAssertFalse(region.contains(point),
                           "the blank probe at \(point) is inside the \(name) control's hit region \(region)")
        }
        return point
    }

    private func typeDraft(_ text: String) {
        tap(composerPoint())
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "tapping the draft has to raise the keyboard")
        app.typeText(text)
    }

    /// The reported bug: draft typed, keyboard put away, tap Send.
    func testSendWithKeyboardDownDoesNotRaiseIt() throws {
        typeDraft("STREAMTEST keyboard down")
        tap(blankPoint())
        XCTAssertFalse(keyboardSettled(), "a tap on the page has to put the keyboard away")
        shot("send-down-1-keyboard-away")
        // Read AFTER the keyboard went away: the button moved when it did, and
        // this is the coordinate the case is about.
        let target = sendPoint()
        print("KEYBOARD-TEST send-with-keyboard-down point=\(target)")
        tap(target)
        let raised = keyboardSettled()
        shot("send-down-2-after-send")
        XCTAssertFalse(raised, "tapping Send raised the keyboard")
    }

    /// Send with the keyboard up leaves the screen to the reply.
    func testSendWithKeyboardUpPutsItAway() throws {
        typeDraft("STREAMTEST keyboard up")
        shot("send-up-1-typed")
        // With the keyboard up the composer sits above it, so this is the other of
        // the two positions the button takes — read from the tree, not carried
        // over from the keyboard-down case.
        let target = sendPoint()
        print("KEYBOARD-TEST send-with-keyboard-up point=\(target)")
        tap(target)
        let stillUp = keyboardSettled()
        shot("send-up-2-after-send")
        XCTAssertFalse(stillUp, "the keyboard stayed up after tapping Send")
    }

    /// The same press handler is on the "+" button, which also focuses the editor.
    func testPlusWithKeyboardDownDoesNotRaiseIt() throws {
        let target = plusPoint()
        print("KEYBOARD-TEST plus point=\(target)")
        tap(target)
        let raised = keyboardSettled()
        shot("plus-down-1-menu")
        XCTAssertFalse(raised, "tapping + raised the keyboard")
    }

    /// The guard must not have broken the ordinary way in.
    func testTappingTheDraftStillRaisesIt() throws {
        XCTAssertFalse(keyboardIsUp, "the keyboard is up on launch")
        tap(composerPoint())
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "tapping the draft did not raise the keyboard")
        shot("draft-tap-1-keyboard-up")
    }

    /// Return is not the Send button: whatever it does, the keyboard stays.
    func testReturnKeepsTheKeyboard() throws {
        typeDraft("STREAMTEST return key\n")
        let stillUp = keyboardSettled()
        shot("return-1-after")
        XCTAssertTrue(stillUp, "Return put the keyboard away")
    }
}
