//
//  GuestConsoleTests.swift
//  DSHPortCUITests
//
//  Proves the debug entry is reachable and usable by a person, not just by the
//  launch-argument self-test.
//
//  Why both exist: GuestSelfTest measures the guest with no UI in the way, which
//  is what the timings need. But "there is a debug entry in the app that boots
//  the guest and runs a command" is a claim about the UI, and the only honest
//  way to check it is to tap the button and read what appears.
//

import XCTest

final class GuestConsoleTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // The web UI has to finish loading before the toolbar is stable; without
        // this the guest button can be found mid-layout at a stale position.
        XCTAssertTrue(app.buttons["guestConsoleButton"].waitForExistence(timeout: 90),
                      "the guest console button never appeared in the toolbar")
    }

    /// Open the console, boot the guest, and check a command's output and exit
    /// code appear on screen.
    func testGuestConsoleBootsAndRunsACommand() throws {
        app.buttons["guestConsoleButton"].tap()

        let stateTitle = app.staticTexts["guestStateTitle"]
        XCTAssertTrue(stateTitle.waitForExistence(timeout: 15), "the console did not open")

        // Boot from the button rather than automatically: the console is a debug
        // tool, and booting a kernel without being asked would be a surprise.
        //
        // Buttons, not a Menu: the first version of this screen put the actions
        // behind a SwiftUI Menu, which the UI test could open but could not
        // then tap ("Failed to not hittable"). Visible buttons are also simply
        // better for a debug screen — the point is to run these four things.
        let bootButton = app.buttons["guestBootButton"]
        XCTAssertTrue(bootButton.waitForExistence(timeout: 10), "no boot button")
        bootButton.tap()

        // The state line only says "已就绪" once island boot returned without
        // error, so waiting for it is waiting for the kernel.
        let ready = NSPredicate(format: "label CONTAINS %@", "已就绪")
        expectation(for: ready, evaluatedWith: stateTitle)
        waitForExpectations(timeout: 60)

        let unameButton = app.buttons["guestUnameButton"]
        XCTAssertTrue(unameButton.waitForExistence(timeout: 10), "no uname button")
        unameButton.tap()

        // The command's stdout is rendered in the log list; find the line.
        let aarch64 = app.staticTexts["aarch64"]
        XCTAssertTrue(aarch64.waitForExistence(timeout: 30),
                      "the guest did not print 'aarch64'")

        // And the exit code line, which is what makes this an execution rather
        // than a repaint.
        let exitLine = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "[exit code: 0]")
        ).firstMatch
        XCTAssertTrue(exitLine.waitForExistence(timeout: 10),
                      "no exit code line appeared for the guest command")
    }
}
