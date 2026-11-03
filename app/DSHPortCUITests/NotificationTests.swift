//
//  NotificationTests.swift
//  DSHPortCUITests
//
//  The three things only a UI-driving test can do for step 16: press the system
//  notification-permission alert, hand focus to another app mid-turn, and tap a
//  delivered notification banner.
//
//  WHY THESE ARE HERE AND NOT IN `step16-acceptance.py`
//  ---------------------------------------------------
//  Everything else about step 16 is measured from the outside: the app's own record of
//  what the system holds (`getDeliveredNotifications`), the session log, and a
//  command-file channel into the app's web view. Three actions have no such instrument:
//
//    * the system permission alert is SpringBoard's, not the app's, so only XCUITest
//      can press it (`app.alerts` / `springboard.alerts`);
//    * backgrounding mid-turn is a home-button press on a springboard;
//    * a delivered banner lives in SpringBoard's notification UI, so tapping it means
//      tapping another process's element.
//
//  A `simctl` sheet cannot do any of the three, and `read_image` is excluded by the
//  task's rules, so a screenshot of a banner would not be an assertion anyway.
//
//  WHAT THIS TEST ASSERTS, AND WHAT IT DELIBERATELY LEAVES TO THE SCRIPT
//  --------------------------------------------------------------------
//  It asserts the ACTIONS succeed and their observable consequences: the alert was
//  answered and the app came up; the app went to the background while a turn was
//  running; a banner appeared in the notification list and tapping it brought the app
//  forward. It does not re-derive the delivered/suppressed tables — those are the
//  acceptance script's job, from `getDeliveredNotifications`, and duplicating the
//  reading here would give two sources for one number.
//

import XCTest

final class NotificationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    /// Press the system notification alert, and nothing else.
    ///
    /// WHY THIS IS SEPARATE FROM THE BANNER TEST. Only XCUITest can press that alert, and
    /// a device keeps the answer — so the grant has to happen once per device, not once
    /// per acceptance case. Bundling it into the banner test made the grant path depend on
    /// banner timing, which is unrelated to whether the alert was answered: measured
    /// twice, the banner assertion failed while the grant had in fact succeeded.
    ///
    /// This test does one thing, so its result means one thing: if it passes, the app is
    /// authorized to notify on this device. `scripts/step16-grant.py` runs it and then
    /// reads `authorization` from the app's own status file as the verdict.
    func testGrantNotificationPermission() throws {
        app.launchArguments = [
            "-DSHPortCTestDrive", "1",
            "-DSHPortCMockPort", "19716",
            "-DSHPortENotifyDump", "1",
        ]
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] =
            (try? String(contentsOf: projectFile("prompts/21-step16-quick-turn.txt"), encoding: .utf8)) ?? "BASHTEST"
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "STEP16-QUICK-DONE"
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")

        // The alert is raised by the app's own `requestAuthorization` on the first
        // `turn/start`, so waiting for it is also a confirmation that a turn really began.
        let asked = answerNotificationAlert("允许")
        attach("grant-answered")
        XCTAssertTrue(asked, "the notification permission alert never appeared")
    }

    /// The springboard, which owns the permission alert and the notification banners.
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// Answer the system notification alert if it appears, and record whether it did.
    ///
    /// The alert only appears once per install, and only when the app asks — which is
    /// the first turn's start. So this waits for it rather than assuming it. If it does
    /// not appear, that is itself a fact worth failing on: either the app asked before
    /// there was a turn (wrong) or it never asked at all (also wrong).
    /// `inForeground` is not decoration. Measured: the alert is drawn over the app,
    /// and a Home press while it is up DISMISSES it — the previous version pressed
    /// Home first and then polled for seven minutes for an alert that no longer
    /// existed. A caller that needs the answer while the app is in front says so, and
    /// the poll then stops as soon as the app is not in front rather than waiting out
    /// the deadline.
    @discardableResult
    private func answerNotificationAlert(_ button: String, inForeground: Bool = false,
                                         timeout: TimeInterval = 420) -> Bool {
        // Two hosts can raise it: SpringBoard draws the alert, but on some iOS
        // versions an XCTest quirk routes it through the app's own alert query. Both
        // are checked, and the wait is generous because the first model turn has to
        // start first.
        let fromApp = app.alerts.firstMatch
        let fromSpringboard = springboard.alerts.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fromApp.waitForExistence(timeout: 2) {
                let choice = fromApp.buttons[button]
                if choice.exists {
                    attach("02a-alert-appeared")
                    choice.tap()
                    return true
                }
            }
            if fromSpringboard.exists {
                let choice = fromSpringboard.buttons[button]
                if choice.exists {
                    attach("02a-alert-appeared")
                    choice.tap()
                    return true
                }
            }
            // A foreground-only caller must not spend the whole deadline polling a
            // prompt that a background transition already dismissed.
            if inForeground, app.state != .runningForeground {
                print("STEP16_NT the app left the foreground while an alert was expected; stopping the poll")
                return false
            }
            // The alert is raised by the app's own `requestAuthorization`, which fires
            // on the first `turn/start`. Nothing else here can hurry that.
            Thread.sleep(forTimeInterval: 1.0)
        }
        return false
    }

    /// Press home so the app goes to the background for real.
    private func pressHome() {
        XCUIDevice.shared.press(.home)
    }

    /// Bring the app forward again WITHOUT relaunching it.
    ///
    /// `app.activate()` on a backgrounded app resumes it; `app.launch()` would start a
    /// new process and destroy the session state the assertions are about.
    private func bringForward() {
        app.activate()
    }

    // MARK: - Tests

    /// The permission alert appears only once a turn is running, and answering it
    /// lets a finished turn reach the phone — with a real banner.
    ///
    /// WHAT WAS WRONG WITH THE PREVIOUS VERSION, AND WHY THIS IS A REWRITE
    /// -------------------------------------------------------------------
    /// Three separate defects, all of them in the test:
    ///
    ///   1. IT PRESSED HOME BEFORE ANSWERING THE ALERT. Measured: the alert is
    ///      drawn over the app, and pressing Home dismisses it — after that the
    ///      test spent 420 s polling for an alert that no longer existed. The
    ///      screenshot `02a-alert-appeared` in the merged regression log is the
    ///      proof it HAD appeared. So the alert is now answered in the FOREGROUND,
    ///      which is also the only state in which "the app asks at turn start" is
    ///      a claim about the app rather than about a backgrounded prompt.
    ///
    ///   2. IT USED A 3-SECOND COMMAND. `prompts/21-step16-quick-turn.txt` sleeps
    ///      3 s, while the comment claimed twenty; the turn therefore ENDED while
    ///      the app was still in the foreground, and the app correctly suppressed
    ///      the notification ("App 在前台，不发"). A test that then waits for a
    ///      banner can only fail. The turn now comes from
    ///      `prompts/26-step16-background-turn.txt`, which runs about 40 s, and it
    ///      is sent AFTER the permission was granted, so the ordering is
    ///      deterministic: foreground, allowed, turn started, backgrounded, turn
    ///      ends behind the app, banner.
    ///
    ///   3. IT DID NOT UNINSTALL THE APP FIRST. iOS asks once per install. A
    ///      device that had already answered — which this one had, from the grant
    ///      test — never shows the alert again, so the assertion "it was asked"
    ///      could not be reproduced by re-running. The caller uninstalls before
    ///      this test (`scripts/step16-grant.py --reset`), and the test asserts the
    ///      state it needs rather than assuming it: if the alert never appears the
    ///      failure says so, which is the difference between "the app did not ask"
    ///      and "this device was already asked".
    ///
    /// WHAT IS ASSERTED, IN ORDER, EACH ONE A SEPARATE CLAIM
    ///   1. no alert at launch (the app must not prompt before there is a turn);
    ///   2. the alert appears at the turn's start, and "允许" is pressed in the
    ///      foreground;
    ///   3. the app is backgrounded while that turn is still running;
    ///   4. the turn ends behind the app;
    ///   5. a banner with this app's own text is on SpringBoard's screen, and its
    ///      label carries the body the plugin sends.
    func testPermissionAlertIsAskedAtTurnStartAndABannerArrives() throws {
        app.launchArguments = [
            "-DSHPortCTestDrive", "1",
            "-DSHPortCMockPort", "19716",
            "-DSHPortENotifyDump", "1",
            "-DSHPortENotifyDrive", "1",
        ]
        let prompt = try String(contentsOf: projectFile("prompts/26-step16-background-turn.txt"),
                                encoding: .utf8)
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] = prompt
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "step16-bg-done"
        app.launch()

        // 1. Nothing is asked at launch. The alert must NOT be here yet; if it
        // is, the app is prompting before there is anything to be notified about,
        // which is the behaviour the task forbids.
        XCTAssertFalse(app.alerts.firstMatch.exists, "the app asked for notification permission at launch")
        attach("01-launch-no-alert")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")

        // 2. The alert, at the turn's start, answered IN THE FOREGROUND.
        //
        // The alert is raised by `requestAuthorization`, which the app calls on
        // the first `turn/start` — so its arrival is also the confirmation that a
        // turn really began. The driver sends the prompt itself once the page is
        // ready, so nothing here has to type.
        let asked = answerNotificationAlert("允许", inForeground: true)
        attach("02-permission-answered-in-foreground")
        XCTAssertTrue(
            asked,
            "the notification permission alert never appeared after the turn started, so the app never asked "
                + "at turn start. (If this device was already asked, it must be uninstalled first — iOS asks "
                + "once per install.)"
        )

        // 3. Background the app while the same turn is still running. The turn is
        // ~40 s and the alert arrives within a couple of seconds of it starting,
        // so this is a genuine foreground→background transition mid-turn.
        let stillRunning = app.staticTexts.allElementsBoundByIndex.map(\.label)
            .contains { $0.contains("step16-bg-") || $0.contains("正在") }
        print("STEP16_NT foreground before home: runningHints=\(stillRunning)")
        pressHome()
        // POLLED, NOT SAMPLED ONCE. Measured: 0.6 s after the Home press `app.state`
        // still reported `runningForeground` (rawValue 4) and the first version of
        // this assertion failed on an app that HAD gone to the background, because a
        // state read is a round trip to a process that is in the middle of resigning
        // active. The same polling idiom is used for the return trip below.
        // THE WITNESS IS SPRINGBOARD, NOT THE APP'S OWN STATE. Measured twice: after
        // `press(.home)` the app's `state` kept answering `runningForeground` (4) for
        // the whole 20 s poll and only read 3 when the assertion finally printed it —
        // the app's own state query is a round trip to a process that is suspended, so
        // it cannot be asked to confirm its own suspension. SpringBoard taking the
        // foreground is the fact the transition actually produces.
        let springboardCame = springboard.wait(for: .runningForeground, timeout: 30)
        attach("03-backgrounded-mid-turn")
        XCTAssertTrue(springboardCame, "SpringBoard never came to the foreground, so the app was not backgrounded")
        print("STEP16_NT backgrounded: springboard=\(springboardCame) appState=\(app.state.rawValue)")

        // 4+5. The turn ends behind the app, and a real banner is drawn.
        //
        // The identifiers below are not guesses: `testDiagnoseNotificationElements`
        // dumps SpringBoard's tree while a notification is on screen, and this query
        // is copied from that dump. On iOS 27 a delivered banner is
        // `BannerNotification` with identifier `NotificationShortLookView`, whose
        // label is "DSH, 现在, <title>, <body>" — so `label CONTAINS "这一轮做完了"`
        // finds it without depending on the bundle name or the timestamp. Polled
        // rather than slept through, because a banner retracts: an earlier version
        // of this test slept 14 s and reported "no notification" for one that had
        // already been delivered and dismissed on its own. The window is the turn's
        // own duration plus delivery, not an arbitrary figure.
        let bannerQuery = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                  "NotificationShortLookView", "这一轮做完了"))
        var bannerSeen = false
        let bannerDeadline = Date().addingTimeInterval(180)
        while Date() < bannerDeadline {
            if bannerQuery.firstMatch.exists {
                bannerSeen = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attach("04-banner-on-home-screen")
        XCTAssertTrue(
            bannerSeen,
            "no banner with this app's text ever appeared; springboard labels seen: "
                + springboard.staticTexts.allElementsBoundByIndex.prefix(25).map(\.label).joined(separator: " | ")
        )
        guard bannerSeen else { return }

        // The body the banner actually drew, recorded as an assertion rather than
        // left to a screenshot. The title is the session's own title and the body
        // is the fixed short sentence the plugin sends.
        let bannerLabel = bannerQuery.firstMatch.label
        print("STEP16_NT banner label=\(bannerLabel)")
        XCTAssertTrue(bannerLabel.contains("这一轮做完了"), "the banner's label was: \(bannerLabel)")

        // THE TAP, ON THE BANNER ITSELF.
        //
        // WHY THE BANNER AND NOT THE NOTIFICATION CENTRE. Measured twice: tapping the
        // `ListCell` in the centre brought the app to the foreground but delivered no
        // `UNNotificationResponse` — the app's own record stayed `taps: []`, so the
        // routing never ran. The centre's cell is a SpringBoard button whose action is
        // "open the app"; a banner's button is the notification itself. The criterion is
        // about what a tap on a NOTIFICATION does, so it is tapped where it is a
        // notification.
        //
        // If the banner has already retracted by the time the poll above first sees it
        // (they retract in about 5 s), the centre is opened and the same
        // `ShortLook.Platter.Content.Seamless` button inside the cell is pressed, which
        // is the element that carries the notification's own action.
        let bannerButton = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "ShortLook.Platter.Content.Seamless"))
        var tapped = false
        if bannerButton.firstMatch.exists {
            bannerButton.firstMatch.tap()
            tapped = true
        } else {
            openNotificationCentre()
            attach("06-notification-centre")
            let cell = deliveredCell(containing: "这一轮做完了")
            guard cell.waitForExistence(timeout: 20) else {
                XCTFail("the notification was in neither the banner nor the notification centre")
                return
            }
            XCTAssertTrue(cell.exists, "the notification was in neither the banner nor the notification centre")
            // The platter inside the cell, not the cell: the cell's own action opens the
            // app without delivering a response, which is the difference measured above.
            let platter = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                      "ShortLook.Platter.Content.Seamless", "这一轮做完了"))
            if platter.firstMatch.exists {
                platter.firstMatch.tap()
            } else {
                cell.tap()
            }
            tapped = true
        }
        XCTAssertTrue(tapped, "there was nothing to tap")

        // The app must come forward, and the tap must reach `handleTap` — which is what
        // makes the routing run at all. Polled, because a single sample read
        // `rawValue 3` for an app that was in the middle of resuming.
        let foregroundDeadline = Date().addingTimeInterval(30)
        while app.state != .runningForeground && Date() < foregroundDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        attach("07-after-tapping-the-notification")
        XCTAssertEqual(app.state, .runningForeground, "tapping the notification did not bring the app forward")

        // Poll for the tap reaching the app, then record what it routed to. The
        // assertion about WHICH session is the acceptance script's (it can read the
        // session id from the log; this process cannot), so here the claim is narrower
        // and exact: the tap was delivered and a navigation was attempted.
        // WHAT THE SYNTHETIC TAP DOES AND DOES NOT PRODUCE — measured, and it decides
        // how the criterion is evidenced.
        //
        // `XCUIElement.tap()` on a SpringBoard notification element brings the app
        // forward, and that is asserted above. It does NOT produce a
        // `UNNotificationResponse`: the app's delegate recorded `taps: []` across three
        // runs of this test, so the response path never ran. SpringBoard treats a
        // synthetic tap on the banner as "activate this application" and the
        // notification's own action — which is what a finger invokes — is not exercised.
        //
        // So the two halves of "tap a notification" are evidenced separately, and this
        // test only claims the half it can see:
        //   * THIS TEST: a banner is delivered and drawn (above), and tapping its area
        //     brings the app to the foreground (above).
        //   * `scripts/step16-acceptance.py tap`: `handleTap` — the delegate's own entry
        //     point — routes to the right session, driven for the running, suspended and
        //     killed states. That covers the routing requirement end to end except for
        //     the OS's dispatch of the response, which only a device (or a human finger)
        //     can produce.
        //
        // The record is read and attached anyway: on a device, or on a future iOS that
        // does deliver the response to a synthetic tap, this is where it would show up,
        // and the report cites it either way.
        let tapDeadline = Date().addingTimeInterval(20)
        while tapCount() == 0 && Date() < tapDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let routed = navigateRecord()
        attach("08-routed")
        print("STEP16_TAP_DELEGATE_CALLS \(tapCount()) routed=\(routed)")
        XCTAssertFalse(
            routed.contains("没有会话 id"),
            "a tap reached the app but carried no session id: \(routed)"
        )
    }

    /// With the permission REFUSED, a later launch must not ask again.
    func testRefusalIsNotAskedAgain() throws {
        // First launch: refuse.
        app.launchArguments = [
            "-DSHPortCTestDrive", "1",
            "-DSHPortCMockPort", "19716",
            "-DSHPortENotifyDrive", "1",
        ]
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] =
            (try? String(contentsOf: projectFile("prompts/21-step16-quick-turn.txt"), encoding: .utf8)) ?? "BASHTEST"
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "STEP16-QUICK-DONE"
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")
        let refused = answerNotificationAlert("不允许")
        attach("06-refused")
        XCTAssertTrue(refused, "the permission alert never appeared on the first launch")

        // Second launch: the alert must not come back, and the app must still work.
        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300),
                      "the app did not come up after a refusal")
        let askedAgain = answerNotificationAlert("允许")
        attach("07-not-asked-again")
        XCTAssertFalse(askedAgain, "the app asked for notification permission a second time after a refusal")
    }

    /// Dump both processes' accessibility trees into a file the report can quote.
    ///
    /// WHY A TEST EXISTS JUST TO WRITE THIS. A notification banner belongs to
    /// SpringBoard, and the element names differ between iOS releases. Rather than guess
    /// a selector and call a missing one "no notification", this test writes what is
    /// actually on screen at four moments, and the selector in the banner test comes
    /// from reading that dump. It is a diagnosis, not an assertion, which is why it
    /// never fails.
    func testDiagnoseNotificationElements() throws {
        app.launchArguments = [
            "-DSHPortCTestDrive", "1",
            "-DSHPortCMockPort", "19716",
            "-DSHPortENotifyDump", "1",
            "-DSHPortENotifyDrive", "1",
        ]
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] =
            (try? String(contentsOf: projectFile("prompts/21-step16-quick-turn.txt"), encoding: .utf8)) ?? "BASHTEST"
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "STEP16-QUICK-DONE"
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")

        var dump = "== before backgrounding ==\n" + app.debugDescription
        pressHome()
        dump += "\n== backgrounded, answering the alert ==\n"
        _ = answerNotificationAlert("允许")
        // The banner's own moment: sampled repeatedly, because it retracts.
        for step in 0..<12 {
            Thread.sleep(forTimeInterval: 1.0)
            dump += "\n== springboard t+\(step)s ==\n" + springboard.debugDescription
        }
        pressHome()
        Thread.sleep(forTimeInterval: 2)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.004))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.5)
        Thread.sleep(forTimeInterval: 3)
        dump += "\n== after dragging for the notification centre ==\n" + springboard.debugDescription
        attach("diagnose-notification-centre")

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("step16-ax-dump.txt")
        try? dump.write(to: out, atomically: true, encoding: .utf8)
        print("STEP16_AX_DUMP \(out.path)")
    }

    /// Which gesture actually opens the notification centre on this iOS version.
    ///
    /// WHY THIS IS A TEST AND NOT A GUESS. The first version of the banner test dragged
    /// from `dy: 0.004` to `dy: 0.95` and the notification centre never opened — the
    /// dump taken afterwards still showed the home screen, so the assertion failed for a
    /// reason that had nothing to do with notifications. Four candidate gestures are
    /// tried in order, each followed by a search for the delivered notification cell, and
    /// the one that works is printed. Never fails: it is a diagnosis.
    func testDiagnoseNotificationCentreGesture() throws {
        app.launchArguments = [
            "-DSHPortCTestDrive", "1",
            "-DSHPortCMockPort", "19716",
            "-DSHPortENotifyDump", "1",
            "-DSHPortENotifyDrive", "1",
        ]
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] =
            (try? String(contentsOf: projectFile("prompts/21-step16-quick-turn.txt"), encoding: .utf8)) ?? "BASHTEST"
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "STEP16-QUICK-DONE"
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300), "the web view never appeared")

        pressHome()
        _ = answerNotificationAlert("允许")
        // Wait until the banner has been seen, so a notification definitely exists.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                  "NotificationShortLookView", "这一轮做完了"))
        _ = banner.firstMatch.waitForExistence(timeout: 40)
        Thread.sleep(forTimeInterval: 4)

        let cell = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                  "ListCell", "这一轮做完了"))

        var findings: [String] = []
        let attempts: [(String, () -> Void)] = [
            ("swipeDown", { self.springboard.swipeDown() }),
            ("drag-from-0.01-to-0.6", {
                let a = self.springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                let b = self.springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                a.press(forDuration: 0.2, thenDragTo: b)
            }),
            ("drag-from-0.02-to-0.9-slow", {
                let a = self.springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
                let b = self.springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 1.0)
            }),
            ("double-swipeDown", {
                self.springboard.swipeDown()
                Thread.sleep(forTimeInterval: 1)
                self.springboard.swipeDown()
            }),
        ]
        for (name, gesture) in attempts {
            gesture()
            Thread.sleep(forTimeInterval: 3)
            let found = cell.firstMatch.exists
            findings.append("\(name) -> cell=\(found)")
            attach("gesture-\(name)")
            if found {
                findings.append("\(name) OPENED THE CENTRE")
                break
            }
            // Close whatever opened, so the next gesture starts from the home screen.
            pressHome()
            Thread.sleep(forTimeInterval: 2)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("step16-gestures.txt")
        try? findings.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("STEP16_GESTURES " + findings.joined(separator: " / "))
    }

    /// Open the notification centre.
    ///
    /// The gesture is the one `testDiagnoseNotificationCentreGesture` measured: a drag
    /// from `dy` 0.01 to 0.6, which reported `cell=true` where `swipeDown()` reported
    /// `cell=false`. A drag that starts at the very top edge and ends past the halfway
    /// point is what iOS 27 wants; a plain swipe of the same length does not open it.
    private func openNotificationCentre() {
        // WAIT FOR THE BANNER TO RETRACT FIRST. A banner sits at the very top of the
        // display, which is exactly where this drag starts, so while one is up the drag
        // is delivered to the banner instead of to the screen edge and the centre never
        // opens. Measured: the same gesture that worked after the banner had gone
        // reported the home screen when it was issued while the banner was up. Five
        // seconds is the retraction delay; the loop confirms the state rather than
        // trusting the number.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "NotificationShortLookView"))
        let deadline = Date().addingTimeInterval(25)
        while banner.firstMatch.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.2, thenDragTo: end)
        Thread.sleep(forTimeInterval: 3)
    }

    /// The delivered notification, by the identifiers the accessibility dump showed.
    private func deliveredCell(containing text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "ListCell", text))
            .firstMatch
    }

    /// What the app's own record says the tap did.
    private func navigateRecord() -> String {
        // The record lives in the app's Documents directory, which the test process can
        // read through the same container path the acceptance script uses.
        let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // UITest runs in its own process, so the app's Documents path is not relative to
        // it. The status file is mirrored into the shared temp directory instead, by the
        // app's dump hook — this helper reads that copy when it is there and says so when
        // it is not, rather than reporting an empty string as a failed navigation.
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("step16-status.json")
        guard let data = try? Data(contentsOf: shared) else {
            _ = container
            return "unreadable-from-test-process"
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notifications = object["notifications"] as? [String: Any],
              let last = notifications["lastNavigation"] as? String
        else { return "no-notification-section" }
        return last
    }

    /// Whether a tap has been recorded yet, read from the app's shared copy.
    private func tapCount() -> Int {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("step16-status.json")
        guard let data = try? Data(contentsOf: shared),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notifications = object["notifications"] as? [String: Any],
              let taps = notifications["taps"] as? [[String: Any]]
        else { return 0 }
        return taps.count
    }

    // MARK: - Helpers

    /// A path inside the checkout, found from this test bundle's own location.
    ///
    /// `#filePath` is the source file, and the checkout root is four directories up from
    /// `app/DSHPortCUITests/`. Reading the prompt from the tree rather than pasting it
    /// means the test and the acceptance script drive the same words.
    private func projectFile(_ relative: String) throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(relative)
    }

    private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshportc-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
