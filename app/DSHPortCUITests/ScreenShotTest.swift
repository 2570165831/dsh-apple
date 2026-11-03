//
//  ScreenShotTest.swift
//  DSHPortCUITests
//
//  Produces the screenshots REPORT-1.md cites: the console after booting the
//  guest and running `uname -m`, and after the deliberate kernel die().
//
//  A screenshot taken from a UI test is the only kind that shows what the app
//  actually rendered at the moment the assertion ran; `simctl io screenshot`
//  from outside can catch a different screen entirely, and did during this work.
//

import XCTest

final class ScreenShotTest: XCTestCase {
    func testCaptureConsoleAfterCommands() {
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["guestConsoleButton"].waitForExistence(timeout: 90)
        app.buttons["guestConsoleButton"].tap()

        _ = app.buttons["guestBootButton"].waitForExistence(timeout: 20)
        app.buttons["guestBootButton"].tap()
        sleep(4)

        app.buttons["guestUnameButton"].tap()
        sleep(3)

        // Let the poll timer pick the lines up before the shot.
        sleep(1)
        attach(app.screenshot(), name: "guest-console-uname")

        app.buttons["guestCpOverwriteButton"].tap()
        sleep(6)
        app.buttons["guestCpArchiveButton"].tap()
        sleep(4)
        attach(app.screenshot(), name: "guest-console-cp")

        // The action row is a wrapping grid, so every button is on screen.
        app.buttons["guestDieButton"].tap()
        sleep(4)
        app.buttons["guestUnameButton"].tap()
        sleep(3)
        attach(app.screenshot(), name: "guest-console-after-die")
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
