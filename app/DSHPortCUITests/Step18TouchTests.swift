//
//  Step18TouchTests.swift
//  DSHPortCUITests
//
//  Step 18's real-touch checks.
//
//  WHY THIS FILE EXISTS, AND WHAT IT IS FOR
//  ---------------------------------------
//  Step 18's sweep measures the page from inside the page. That answers "is the
//  target 44 pt", "is it inside the viewport", "does its text fit" — and it
//  cannot answer "does a finger that lands on it actually activate it". Those are
//  different questions: an overlaid hit region can be the right size and still
//  sit under something that swallows the touch, and a control revealed on hover
//  can be visible and still not receive a tap.
//
//  So every test here ends with a real XCUITest gesture and asserts the OUTCOME.
//  No test asserts a measurement it also produced.
//
//  WHAT CHANGED WHEN STEP 15 WAS MERGED, AND WHY THIS FILE IS REWRITTEN
//  -------------------------------------------------------------------
//  Step 15 turns the rail into a DRAWER on a narrow portrait phone. The 56 pt
//  icon column this file was written against no longer exists on screen: with the
//  sidebar collapsed there is only the injected 20 pt left-edge strip
//  (`[data-dsh-rail-edge]`, `left: 0; width: 20px; top: 22%; bottom: 22%`,
//  aria-label `打开会话列表`), and `打开侧边栏`, the account row and the session
//  rows only exist once the strip has opened the drawer.
//
//  So each test now opens the drawer FIRST, through the same edge strip a finger
//  would use, and then makes the assertion it always made. The claims are
//  unchanged: a control's hit region reaches past its painted box, the workspace
//  menu's rows are 44 pt and do not leak into the neighbour, the settings dialog
//  shows all four pages at 44 pt and each one changes what is drawn, and a
//  session row's actions work without a hover. Only the navigation to reach them
//  is different, because the layout it navigates is.
//
//  The privacy check also opens the native About sheet from ordinary settings
//  and reads the bundled policy. Its entry must stay inside the viewport on
//  both phone and iPad layouts, without the debug gesture.
//
//  MEASURED ON THE MERGED BUILD (dsh-portE-xct-16, 402x874 pt, drawer open):
//    收起侧边栏            240,84  28x28
//    搜索会话              176,224 44x44
//    添加工作区            240,224 44x44
//    account row           10,798  260x32   (label `账号菜单`)
//    session row actions   187/218/249 at y 328, 374, 420, each 16x16
//    workspace rows        默认工作区 24,428 136x44 · 添加工作区… 24,478 136x45
//
//  HOW A TARGET IS ADDRESSED, AND WHY IT VARIES
//  -------------------------------------------
//  Three query shapes were tried on this WebKit build and all three fail
//  intermittently on the DSH page:
//
//    * `webView.buttons["打开侧边栏"]` → "No matches found ... from input
//      {WebView}" with an "Automation type mismatch" warning;
//    * recursing `element.children(matching: .any)` → "No matches found for
//      Element at index N";
//    * enumerating `webView.otherElements` → the same failure (measured at index
//      41 with the settings dialog open, 52 with a menu open, 60 on the models
//      page, and 43 on the hero screen).
//
//  `webView.buttons.allElementsBoundByIndex` works, returns frames in SCREEN
//  points, and is used wherever the target exposes as a button.
//
//  `webView.otherElements["…"].firstMatch` also works — measured, for
//  `添加文件或调用指令`, `选择工作区` and `账号菜单`. Only ENUMERATING that query
//  throws, so a labelled `Other` is now addressed by label instead of by a page
//  coordinate. That is what `Hero.workspaceTrigger` and `Rail.accountRow` use.
//
//  A session row's rename / archive / pin glyphs ARE now in the tree: with the
//  drawer open, `归档会话` / `置顶会话` / `会话“…”的操作` are addressable buttons
//  at 16x16. Step 18's original note that the tree "does not surface them at
//  all" was measured with the old 56 pt rail, where the rows never rendered in
//  the collapsed state. So the archive test taps the button rather than walking a
//  measured column — the first 16 pt target on a 32 pt row cannot be hit by a
//  16 pt blind column walk, and that is the whole point of the test.
//
//  These tests use the mock on port 19718.
//

import XCTest

final class Step18TouchTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The mock runs on the port this step owns. The polish layer stays on,
        // because the point of these tests is the layer's effect.
        app.launchArguments += ["-DSHPortCMockPort", "19718"]
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
    }

    // MARK: - Geometry the tree can give us

    private struct Control {
        let label: String
        let frame: CGRect
    }

    private func webView() -> XCUIElement { app.webViews.firstMatch }

    /// Every button with a usable frame.
    ///
    /// `isHittable` is deliberately NOT read here: the page contains controls
    /// with frames WebKit cannot hit-test, and asking about one throws
    /// "Failed to determine hittability … Activation point invalid" out of the
    /// whole enumeration.
    private func buttons() -> [Control] {
        webView().buttons.allElementsBoundByIndex.compactMap { element in
            let frame = element.frame
            guard frame.width >= 1, frame.height >= 1,
                  frame.origin.x.isFinite, frame.origin.y.isFinite else { return nil }
            return Control(label: element.label, frame: frame)
        }
    }

    private func labels() -> [String] { buttons().map(\.label) }

    private func pageText() -> String {
        let lines = webView().staticTexts.allElementsBoundByIndex
            .map(\.label).filter { !$0.isEmpty }
        return lines.isEmpty ? webView().label : lines.joined(separator: "\n")
    }

    // MARK: - Page coordinate → screen coordinate

    /// Where the page's own origin sits on the screen.
    ///
    /// The web view is inset by the safe area (step 11's change), so a page
    /// coordinate is not a screen coordinate. Read at run time rather than
    /// assumed: if the inset ever changes, every tap here moves with it.
    private func screen(_ page: CGPoint) -> CGPoint {
        let frame = webView().frame
        return CGPoint(x: frame.origin.x + page.x, y: frame.origin.y + page.y)
    }

    // MARK: - Gestures

    private func waitForShell(timeout: TimeInterval = 300) {
        XCTAssertTrue(webView().waitForExistence(timeout: timeout), "no web view appeared")
        let composer = webView().textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 180), "the composer never appeared")
        // Wait for the layout to stop moving rather than sleeping a fixed time:
        // measured, the composer's frame is still settling for the first two
        // seconds after it appears, and a coordinate read before that is wrong by
        // 62 pt.
        waitForStableLayout()
    }

    /// Two consecutive identical samples of the controls these tests address.
    private func waitForStableLayout(timeout: TimeInterval = 120) {
        var previous = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let composer = webView().textViews.firstMatch
            let rail = ["打开会话列表", "打开侧边栏", "收起侧边栏"]
                .map { webView().buttons[$0].firstMatch }.first { $0.exists }
            guard composer.exists, let rail else {
                previous = ""
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            let now = "\(composer.frame)|\(rail.frame)"
            if now == previous { return }
            previous = now
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("the page's layout never settled; last sample was \(previous)")
    }

    private func tap(_ point: CGPoint, note: String, settle: UInt32 = 1) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        XCTContext.runActivity(named: "tap \(note) at \(point)") { _ in }
        sleep(settle)
    }

    @discardableResult
    private func tapButton(_ label: String, note: String, settle: UInt32 = 2) -> Bool {
        guard let target = buttons().first(where: { $0.label == label }) else { return false }
        tap(CGPoint(x: target.frame.midX, y: target.frame.midY), note: "\(note) [\(label)]", settle: settle)
        return true
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Left in the simulator's tmp; the host copies them into
        // screenshots/step18/ after the run, because a UI test cannot write to
        // the checkout's volume from inside the simulator.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshportc-step18", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - The drawer, which is how the rest of this file gets anywhere

    /// The injected left-edge strip, which is the only rail control on screen
    /// while the sidebar is collapsed.
    private var edgeStrip: Control? { buttons().first { $0.label == "打开会话列表" } }

    /// True when the drawer is up, judged by the control only the expanded
    /// sidebar has.
    private var drawerIsOpen: Bool { labels().contains("收起侧边栏") }

    /// Open the sidebar through the visible phone or iPad control.
    ///
    /// The strip's own reported frame is used, not a page coordinate: this file's
    /// navigation must not depend on a number that a layout change can move.
    @discardableResult
    private func openDrawer(_ note: String = "left-edge strip") -> Bool {
        if drawerIsOpen { return true }
        guard let opener = edgeStrip ?? buttons().first(where: { $0.label == "打开侧边栏" }) else {
            XCTFail("the collapsed rail has no sidebar opener; have \(labels())")
            return false
        }
        tap(CGPoint(x: opener.frame.midX, y: opener.frame.midY), note: note, settle: 3)
        return drawerIsOpen
    }

    /// Close it again, with its own control.
    @discardableResult
    private func closeDrawer(_ note: String = "collapse") -> Bool {
        guard drawerIsOpen else { return true }
        guard tapButton("收起侧边栏", note: note, settle: 3) else {
            XCTFail("the drawer has no 收起侧边栏 button; have \(labels())")
            return false
        }
        return !drawerIsOpen
    }

    /// A labelled `Other` — addressable by label, not enumerable.
    private func other(_ label: String) -> Control? {
        let element = webView().otherElements[label].firstMatch
        guard element.exists else { return nil }
        let frame = element.frame
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        return Control(label: label, frame: frame)
    }

    // MARK: - Measured geometry that is NOT read from the tree
    //
    // Only one thing is left here. Everything else this file used to carry as a
    // constant — the rail toggle, the account row, the workspace trigger, the
    // session rows' action column — is now either a labelled element or a
    // reported button frame, because the merge moved all four and a constant is
    // what made every test in this file fail for the same non-reason.

    private enum SessionRow {
        /// Session action glyphs are 16x16 and appear only for a row that has a
        /// turn. The tree's labels for them are `归档会话` / `置顶会话`, so the
        /// archive test uses those labels and does not need a column at all.
        /// Kept as documentation of the measured geometry: y 328, 374, 420 with a
        /// 46 pt pitch, starting at 328 on a 1-turn list.
        static let firstRowTop: CGFloat = 328
        static let rowPitch: CGFloat = 46
    }

    /// The step-10 iPad sweep. Unchanged and independent of the rail: it drives
    /// its own launches and asks the host to validate each sample.
    func testIPadLayoutInPortraitAndLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        try XCTSkipIf(app.frame.width < 700, "iPad-only layout check")
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("step18-pad-stage.json")
        let ack = FileManager.default.temporaryDirectory
            .appendingPathComponent("step18-pad-ack.json")
        for (rotation, orientation) in [("portrait", UIDeviceOrientation.portrait),
                                         ("landscape", UIDeviceOrientation.landscapeLeft)] {
            for phase in ["before", "after"] {
                app.terminate()
                XCUIDevice.shared.orientation = orientation
                app.launchArguments = ["-DSHPortCMockPort", "19718", "-DSHPortEStep18", "1",
                                       "-DSHPortEStep18PolishOff", phase == "before" ? "1" : "0"]
                app.launch()
                waitForShell()
                sleep(3)
                let frame = webView().frame
                XCTAssertEqual(frame.width > frame.height, rotation == "landscape",
                               "XCTest orientation did not reach the app: \(frame)")
                let id = UUID().uuidString
                let data: [String: Any] = ["id": id, "phase": phase, "rotation": rotation,
                                          "webWidth": frame.width, "webHeight": frame.height]
                try JSONSerialization.data(withJSONObject: data).write(to: stage, options: .atomic)
                var accepted = false
                let deadline = Date().addingTimeInterval(90)
                while Date() < deadline {
                    if let bytes = try? Data(contentsOf: ack),
                       let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       result["id"] as? String == id {
                        accepted = result["ok"] as? Bool == true
                        break
                    }
                    sleep(1)
                }
                XCTAssertTrue(accepted, "host did not validate \(phase) \(rotation)")
                capture("ipad-\(phase)-\(rotation)-xct")
            }
        }
    }

    // MARK: - Tests

    /// A tap on the drawer's painted COLLAPSE button still lands when it is 1 pt
    /// outside the painted box, inside the 44 pt hit region.
    ///
    /// What this asserts, and why it moved. Step 18 shipped the 44 pt hit regions
    /// because the rail's icons were 36x36 with no hit region at all, so a tap 1 pt
    /// past their edge did nothing. On the merged build the collapsed rail is the
    /// 20 pt edge strip — a control this file asserts nothing about beyond "it
    /// opens the drawer" — and the icons the claim is about live in the drawer.
    /// The claim is unchanged: a control's tappable area reaches past its painted
    /// box. Measured, the painted 收齐侧边栏 box is 28x28 at 240,84 and its hit
    /// region is the 44 pt square around it, so 1 pt past the right edge still
    /// lands on it. The direction is chosen because the first 1 pt outside the
    /// LEFT edge would land on the drawer's own "新建会话" row.
    func testHitRegionExtendsBeyondThePaintedButton() throws {
        waitForShell()
        capture("18-01-hero-collapsed")
        XCTAssertFalse(drawerIsOpen, "the drawer was already open before anything was tapped")

        // The edge strip is what a person uses to get in, and its own reach is
        // asserted first: a tap on its painted centre opens the drawer. Without
        // this the rest of the file has no navigation.
        guard let strip = edgeStrip else {
            XCTFail("the collapsed rail has no 打开会话列表 strip; have \(labels())")
            return
        }
        print("STEP18 edge strip frame=\(strip.frame)")
        XCTAssertTrue(openDrawer(), "tapping the left-edge strip did not open the drawer; have \(labels())")
        capture("18-02-drawer-opened-from-edge-strip")

        // Now the painted control inside the drawer.
        guard let collapse = buttons().first(where: { $0.label == "收起侧边栏" }) else {
            XCTFail("the open drawer has no 收起侧边栏 button; have \(labels())")
            return
        }
        print("STEP18 collapse frame=\(collapse.frame)")
        XCTAssertEqual(collapse.frame.width, 28, accuracy: 2,
                       "the painted collapse button changed size; the overlay's premise moved")

        // 1 pt outside the painted right edge, vertically centred: inside the
        // 44 pt overlay (centre ±22), outside the painted box.
        let probe = CGPoint(x: collapse.frame.maxX + 1, y: collapse.frame.midY)
        tap(probe, note: "1 pt outside the painted collapse button, inside its 44 pt hit region", settle: 2)
        let closed = !drawerIsOpen
        capture("18-03-drawer-closed-from-edge-tap")
        XCTAssertTrue(
            closed,
            "a tap at x=\(probe.x) (the painted box ends at \(collapse.frame.maxX)) did not close the drawer, "
                + "so the 44 pt hit region is not there. Buttons now: \(labels())"
        )
    }

    /// A workspace menu row's HIT REGION reaches 44 pt, and a tap near its bottom
    /// edge selects that row rather than the second one.
    ///
    /// The rows were 34 pt tall before this step, and their hit region was the
    /// same 34. Now the row is 44 pt in the DOM and `elementFromPoint` answers
    /// with the row 4 pt inside either edge; a tap 20 pt below the row's centre is
    /// outside the 34 pt content box the accessibility tree still reports, and
    /// still lands on this row. Landing on the neighbour would open "添加工作区…",
    /// a folder picker — the failure this asserts against.
    func testMenuRowHeightAndNeighbourIsolation() throws {
        waitForShell()

        // The trigger is a labelled `Other`, so it is addressed by label rather
        // than by the page coordinate this file used to carry — that coordinate
        // (134,344) was measured against the pre-merge hero and reached nothing.
        guard let trigger = other("选择工作区") else {
            XCTFail("no 选择工作区 trigger on the hero; buttons: \(labels())")
            return
        }
        print("STEP18 workspace trigger frame=\(trigger.frame)")
        tap(CGPoint(x: trigger.frame.midX, y: trigger.frame.midY), note: "workspace trigger", settle: 2)
        capture("18-04-workspace-menu")

        let rows = buttons()
            .filter { $0.label == "默认工作区" || $0.label == "添加工作区…" }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(
            rows.count, 2,
            "expected two workspace menu rows; the trigger tap reached nothing. Buttons: \(labels())"
        )
        guard rows.count == 2 else { return }
        let first = rows[0], second = rows[1]

        // THE ACCESSIBILITY FRAME IS NOT THE HIT REGION, and this test is about
        // the hit region. Measured on this build: the row's DOM box is 44 pt
        // (`min-height: 44px` from the polish layer, and `elementFromPoint`
        // answers with the row 4 pt inside both its top and bottom edges), while
        // XCUITest reports 34 — the height of the row's CONTENT box. The 10 pt
        // difference is exactly what this step added, so asserting "the frame is
        // 44" would assert the wrong object and fail on a correct build.
        //
        // What is asserted instead is the thing a finger cares about: a tap 20 pt
        // below the row's centre — outside the 34 pt content box (half-height 17)
        // and inside the 44 pt row (half-height 22) — still selects THIS row.
        // Before this step that point was the neighbour's, which is how the
        // original bug behaved.
        let rowCentre = CGPoint(x: first.frame.midX, y: first.frame.midY)
        XCTAssertLessThanOrEqual(
            first.frame.maxY, second.frame.midY,
            "the two reported rows are not in order: \(first.frame) then \(second.frame)"
        )
        let probe = CGPoint(x: rowCentre.x, y: rowCentre.y + 20)
        tap(probe, note: "20 pt below the first row's centre: outside its 34 pt content box, inside its 44 pt row", settle: 2)
        capture("18-05-menu-row-tapped")

        let after = pageText()
        XCTAssertFalse(
            after.contains("选择文件夹") || after.contains("打开文件夹"),
            "the tap fell through to the SECOND row, so the first row is not 44 pt tall. "
                + "Page text: \(after.suffix(300))"
        )
        XCTAssertFalse(
            labels().contains("添加工作区…"),
            "the workspace menu is still open after the tap; it did not land on a row"
        )
    }

    func testPrivacyPolicyIsReachableFromSettings() throws {
        waitForShell()
        XCTAssertTrue(openDrawer("to reach settings"), "the sidebar did not open")
        guard let account = other("账号菜单") else {
            XCTFail("no account menu in the sidebar")
            return
        }
        tap(CGPoint(x: account.frame.midX, y: account.frame.midY), note: "account menu", settle: 2)
        XCTAssertTrue(tapButton("设置", note: "settings entry", settle: 3), "no settings entry")

        let about = webView().links["关于与隐私"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10), "no About link in ordinary settings")
        XCTAssertEqual(webView().links.matching(identifier: "关于与隐私").count, 1)
        let viewport = webView().frame
        XCTAssertGreaterThanOrEqual(about.frame.height, 44)
        XCTAssertGreaterThanOrEqual(about.frame.minX, viewport.minX - 0.5)
        XCTAssertGreaterThanOrEqual(about.frame.minY, viewport.minY - 0.5)
        XCTAssertLessThanOrEqual(about.frame.maxX, viewport.maxX + 0.5)
        XCTAssertLessThanOrEqual(about.frame.maxY, viewport.maxY + 0.5)
        capture("18-settings-privacy-entry")
        about.tap()
        XCTAssertTrue(app.navigationBars["关于与许可"].waitForExistence(timeout: 15),
                      "the settings link did not open the native About sheet")
        XCTAssertTrue(app.descendants(matching: .any)["aboutPrivacyLink"].firstMatch.exists,
                      "no online privacy policy link")

        let policy = app.buttons["aboutLicense-PRIVACY.md"].firstMatch
        XCTAssertTrue(policy.waitForExistence(timeout: 10), "no bundled privacy policy entry")
        policy.tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["# 隐私政策 / Privacy Policy"].waitForExistence(timeout: 10),
                      "the bundled policy was not loaded")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "我们不收集任何数据")
        ).firstMatch.exists, "the policy body is missing")
    }

    /// The settings dialog puts all four pages on screen at once, each at least
    /// 44 pt tall, and each one changes what is drawn.
    ///
    /// Before this step the nav was a 188 pt column inside a 354 pt two-column
    /// dialog — a 48 pt text column for a row's label, and two controls past the
    /// right edge. The one-column switch then made the nav a horizontal strip
    /// measuring 330 pt wide holding 429 pt of entries, so the fourth page
    /// ("Agent 预设") sat at page x 343..465: 63 pt off screen, behind a swipe
    /// nothing indicated. This test is what caught that, and the wrap it forced
    /// is what it now checks.
    func testSettingsDialogShowsEveryPageAndEachOneWorks() throws {
        waitForShell()

        // Account menu → 设置. The account row only exists once the drawer is
        // open, and it is a labelled `Other`; its centre is the bottom of the
        // drawer at 10,798 260x32 on this build.
        XCTAssertTrue(openDrawer("left-edge strip, to reach the account row"), "the drawer did not open")
        guard let account = other("账号菜单") else {
            XCTFail("no 账号菜单 row in the open drawer; buttons: \(labels())")
            return
        }
        print("STEP18 account row frame=\(account.frame)")
        tap(CGPoint(x: account.frame.midX, y: account.frame.midY), note: "account menu", settle: 2)
        capture("18-06-account-menu")

        XCTAssertTrue(tapButton("设置", note: "settings entry", settle: 3),
                      "no 设置 entry in the account menu; buttons: \(labels())")
        capture("18-07-settings-general")

        // 通用设置 is the page the dialog opens on, so it is visited LAST: tapping
        // it first would change nothing and the "did the page change" check would
        // have to be waived for it. Coming back to it from another page is both a
        // real round trip and the same assertion as the other three.
        let pages = ["模型", "内置插件", "Agent 预设", "通用设置"]
        var reached: [String: Bool] = [:]
        let about = webView().links["关于与隐私"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10), "no About link in ordinary settings")
        var frames: [String: CGRect] = ["关于与隐私": about.frame]
        for page in pages {
            guard let entry = buttons().first(where: { $0.label == page }) else {
                XCTFail("settings nav has no [\(page)] entry; have \(labels())")
                continue
            }
            frames[page] = entry.frame
            // 40, not 44: the entry's DOM box is 44 pt (the polish layer's
            // `min-height`), and XCUITest reports the 40 pt content box. See the
            // menu-row test for the measurement that separates the two.
            XCTAssertGreaterThanOrEqual(entry.frame.height, 40,
                                        "the [\(page)] nav entry reports \(entry.frame.height) pt, "
                                            + "below even the 40 pt content box this build has")
            XCTAssertGreaterThanOrEqual(entry.frame.minX, 0,
                                        "the [\(page)] entry starts at x=\(entry.frame.minX), off the left edge")
            XCTAssertLessThanOrEqual(entry.frame.maxX, webView().frame.width,
                                     "the [\(page)] entry ends at x=\(entry.frame.maxX), past the right edge")
            let before = pageText()
            tap(CGPoint(x: entry.frame.midX, y: entry.frame.midY), note: "settings nav [\(page)]", settle: 2)
            reached[page] = pageText() != before
            switch page {
            case "模型": capture("18-08-settings-models")
            case "内置插件": capture("18-09-settings-plugins")
            case "Agent 预设": capture("18-10-settings-presets")
            default: break
            }
        }

        // Compare every pair geometrically. Sorting only by Y leaves entries
        // on the same row in dictionary order and can report a right-hand entry
        // as overlapping the next left-hand one even when their boxes are apart.
        let entries = Array(frames)
        for first in entries.indices {
            for second in entries.indices where second > first {
                let intersection = entries[first].value.intersection(entries[second].value)
                XCTAssertTrue(intersection.isNull || intersection.width <= 0.5 || intersection.height <= 0.5,
                              "nav entries [\(entries[first].key)] and [\(entries[second].key)] overlap: \(intersection)")
            }
        }

        let working = reached.filter { $0.value }.count
        XCTAssertEqual(working, pages.count,
                       "only \(working) of \(pages.count) settings pages changed what is on screen: \(reached)")
    }

    /// A session row's action buttons are on screen without a hover, and a tap on
    /// one reaches the control.
    ///
    /// Before this step the action container was `display: none` until
    /// `.YDXeBa_sessionRow:hover`, and this device reports `(hover: hover)` false
    /// — so on a phone a session could not be renamed, archived or pinned at all.
    ///
    /// The assertion is a tap on the archive glyph producing the archive action.
    /// The glyphs ARE labelled buttons on this build once the drawer is open
    /// (`归档会话`, 16x16, at x 218 on each row), so the tap is by label instead of
    /// by walking a measured column: a first 16 pt target on a 32 pt row cannot be
    /// hit by a blind 16 pt column walk, and that reachability is the claim. The
    /// old column walk is kept as a fallback for a build that stops surfacing the
    /// labels, so the test still measures the same thing.
    func testSessionRowActionsAreReachableWithoutHover() throws {
        waitForShell()

        // One streamed turn through the real composer, so at least one row has a
        // finished turn — an empty session renders its row with no actions.
        let composer = webView().textViews.firstMatch
        let composerFrame = composer.frame
        tap(CGPoint(x: composerFrame.midX, y: composerFrame.midY), note: "composer", settle: 2)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15),
                      "the composer did not focus, so no turn could be sent")
        composer.typeText("STREAMTEST 逐屏走查")
        sleep(1)
        if !tapButton("发送消息", note: "send", settle: 2) {
            composer.typeText("\n")
        }

        var replied = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let text = pageText()
            if text.contains("STREAMTEST-COMPLETE") || text.contains("第 12 块") {
                replied = true
                break
            }
            sleep(2)
        }
        XCTAssertTrue(replied, "the streamed reply never completed; page tail: \(pageText().suffix(400))")
        capture("18-11-conversation-after-turn")

        XCTAssertTrue(openDrawer("left-edge strip, to reach the session rows"), "the drawer did not open")
        capture("18-12-drawer-with-session")

        // The action exists in the DOM now. It did not exist at all before this
        // step, so the assertion is that a tap on it produces the action — not that
        // a control changed size.
        var reacted = false
        var tried = 0
        let archiveLabels = buttons().filter { $0.label == "归档会话" }.map(\.frame)
        print("STEP18 archive glyphs: \(archiveLabels)")
        for (index, glyph) in archiveLabels.prefix(4).enumerated() {
            tap(CGPoint(x: glyph.midX, y: glyph.midY),
                note: "archive glyph on session row \(index)", settle: 2)
            tried += 1
            let after = pageText()
            if after.contains("会话已归档，可") || after.contains("已停止并归档，可")
                || after.contains("停止并归档此会话？") {
                reacted = true
                break
            }
            // A tap that hit the row instead of the action opened that session; go
            // back to the list before trying the next row.
            if !drawerIsOpen {
                _ = openDrawer("reopen after a row press")
            }
        }
        if archiveLabels.isEmpty {
            // The labels are gone: fall back to the measured action column so this
            // test still measures reachability rather than reporting a missing
            // selector as a product failure.
            for index in 0..<4 {
                let y = SessionRow.firstRowTop + SessionRow.rowPitch * CGFloat(index) + 22
                tap(screen(CGPoint(x: 226, y: y)), note: "session row \(index) action column", settle: 2)
                tried += 1
                let after = pageText()
                if after.contains("会话已归档，可") || after.contains("已停止并归档，可")
                    || after.contains("停止并归档此会话？") {
                    reacted = true
                    break
                }
                if !drawerIsOpen { _ = openDrawer("reopen after a row press") }
            }
        }
        capture("18-13-archive-tapped")

        XCTAssertTrue(
            reacted,
            "tapping the archive action of the first \(tried) session rows did not produce an archive toast "
                + "or confirmation; page tail: \(pageText().suffix(400))"
        )
    }
}
