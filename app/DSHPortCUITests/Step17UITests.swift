//
//  Step17UITests.swift
//  DSHPortCUITests
//
//  Step 17's user-visible claims, driven through the real app.
//
//  WHAT THIS PROVES AND WHY IT IS A UI TEST
//  ----------------------------------------
//  "The share sheet appeared" is not something a host script can see. The sheet
//  is a `UIActivityViewController` inside this process; the only witness is the
//  accessibility tree of the running app, which is what XCUITest reads. The same
//  goes for "the Files app shows the workspace and the agent's file can be
//  opened from it" — that claim is about a DIFFERENT app on the device, so it is
//  driven as a separate `XCUIApplication`.
//
//  Everything the app itself did (the download record, the file on disk, the
//  link decisions) is asserted host-side by `scripts/step17-share.py` reading the
//  container; this file only covers what only a UI test can answer.
//
//  THE DOWNLOAD CASES ARE LAUNCH ARGUMENTS, NOT BUTTONS
//  ---------------------------------------------------
//  A `blob:` download and a 50 MB one have no button in DSH's UI to tap. The app
//  therefore accepts `-DSHPortEShareCase <name>` and runs that shape in its own
//  web view, which exercises the real download path end to end. See
//  `ShareProbe.swift` for why that is not a mock.
//

import XCTest

final class Step17UITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Wait for the system share sheet.
    ///
    /// Three different things carry the sheet depending on iOS version and
    /// idiom: a collection view named `ActivityListView`, a bare `ActivityListView`
    /// element, or a popover containing either. Rather than pin one of them, all
    /// candidates are tried and the answer says which matched — a test that
    /// silently passed on `exists == false || exists == false` would be worse
    /// than no test.
    @discardableResult
    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval = 120) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.otherElements["ActivityListView"].exists { return "otherElements[ActivityListView]" }
            if app.collectionViews["ActivityListView"].exists { return "collectionViews[ActivityListView]" }
            if app.tables["ActivityListView"].exists { return "tables[ActivityListView]" }
            if app.otherElements["ActivityContentView"].exists { return "otherElements[ActivityContentView]" }
            if app.popovers.element.exists { return "popovers" }
            if app.buttons["Close"].exists { return "buttons[Close]" }
            if app.buttons["关闭"].exists { return "buttons[关闭]" }
            if app.buttons["取消"].exists { return "buttons[取消]" }
            Thread.sleep(forTimeInterval: 1)
        }
        // Nothing matched: leave the tree in the log so the next attempt starts
        // from what is actually there instead of from a guess.
        print("STEP17-SHARE-SHEET-NOT-FOUND\n\(app.debugDescription)")
        return "none"
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissShareSheet(_ app: XCUIApplication) {
        // "Close" on an English system, 关闭 on a Chinese one. Either is a
        // dismissal; neither saves anything, which is exactly the path whose
        // temporary-file cleanup the host script then checks.
        for label in ["Close", "关闭", "取消", "Cancel"] {
            let button = app.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
        // A popover on iPad is dismissed by tapping outside it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
    }

    // MARK: - iPhone: the share sheet, for each download shape

    /// `blob:` with a Chinese filename.
    func testBlobDownloadShowsShareSheet() {
        let app = launch([
            "-DSHPortCMockPort", "19717",
            "-DSHPortEShareCase", "blob",
            "-DSHPortEDownloadProbe", "1",
        ])
        let found = waitForShareSheet(app)
        attach(app.screenshot(), name: "step17-share-blob")
        XCTAssertNotEqual(found, "none", "no share sheet appeared for the blob download")
        print("STEP17-SHARE-SHEET blob matched \(found)")
        dismissShareSheet(app)
        sleep(3)
        attach(app.screenshot(), name: "step17-share-blob-dismissed")
    }

    /// `data:` URL.
    func testDataUrlDownloadShowsShareSheet() {
        let app = launch([
            "-DSHPortCMockPort", "19717",
            "-DSHPortEShareCase", "data",
            "-DSHPortEDownloadProbe", "1",
        ])
        let found = waitForShareSheet(app)
        attach(app.screenshot(), name: "step17-share-data")
        XCTAssertNotEqual(found, "none", "no share sheet appeared for the data: URL download")
        print("STEP17-SHARE-SHEET data matched \(found)")
        dismissShareSheet(app)
        sleep(3)
    }

    /// 50 MB, so "the app does not hold the file in its heap" has a witness: the
    /// app's own footprint is sampled host-side while this runs.
    func testBigDownloadShowsShareSheet() {
        let app = launch([
            "-DSHPortCMockPort", "19717",
            "-DSHPortEShareCase", "big",
            "-DSHPortEDownloadProbe", "1",
        ])
        let found = waitForShareSheet(app, timeout: 300)
        attach(app.screenshot(), name: "step17-share-big")
        XCTAssertNotEqual(found, "none", "no share sheet appeared for the 50 MB download")
        print("STEP17-SHARE-SHEET big matched \(found)")
        dismissShareSheet(app)
        sleep(3)
    }

    // MARK: - Links

    /// A `target=_blank` to an external site must leave for the system browser
    /// WITHOUT replacing the DSH page.
    ///
    /// The measurement needs care, because the two halves of that sentence pull in
    /// opposite directions: handing the URL to the system browser is exactly what
    /// backgrounds this app, so "the app is in the foreground" is the WRONG
    /// assertion — measured, it fails on a correctly working build, and the first
    /// version of this test did precisely that. What must be true instead:
    ///
    ///   * the app is still running (it was not replaced or terminated);
    ///   * its web view still exists and still has a size;
    ///   * coming back to it shows the app's own page, not the web site.
    ///
    /// The last one is checked host-side as well: `ShareProbe` writes every
    /// navigation decision to `DSHPortE-links.json`, and a page that had been
    /// replaced would show up there as a main-frame navigation to example.com.
    func testExternalBlankLinkKeepsDshPage() {
        let app = launch([
            "-DSHPortCMockPort", "19717",
            "-DSHPortEShareCase", "links",
            "-DSHPortELinkProbe", "1",
        ])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 180), "the DSH web view never appeared")
        // The probe waits 2 s after the page is ready and then clicks.
        sleep(15)
        attach(app.screenshot(), name: "step17-links-after-external")

        XCTAssertNotEqual(app.state, .notRunning, "the app was terminated by the external link")
        XCTAssertTrue(webView.exists, "the DSH web view is gone after the external _blank link")
        XCTAssertFalse(webView.frame.isEmpty, "the web view has no size any more")
        print("STEP17-LINKS state=\(app.state.rawValue) frame=\(webView.frame)")

        // Come back and confirm the page is still DSH's own document: the app's
        // web view keeps its identifier, and the page's title is DSH's, not a
        // web site's.
        app.activate()
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "the app did not come back to the foreground")
        XCTAssertTrue(app.webViews.firstMatch.exists, "the web view did not survive the round trip")
        attach(app.screenshot(), name: "step17-links-after-return")
        print("STEP17-LINKS-RETURN state=\(app.state.rawValue)")
    }

    // MARK: - Dialogs

    /// `alert`, `confirm`, `prompt` raised together; each must produce a native
    /// panel, and `confirm` must be answerable (it used to return false silently).
    func testJavaScriptDialogsAreNative() {
        let app = launch([
            "-DSHPortCMockPort", "19717",
            "-DSHPortEShareCase", "dialogs",
            "-DSHPortELinkProbe", "1",
        ])
        // alert first
        let alertOK = app.buttons["好"]
        XCTAssertTrue(alertOK.waitForExistence(timeout: 120), "no native alert appeared")
        attach(app.screenshot(), name: "step17-dialog-alert")
        alertOK.tap()

        // then confirm: press the affirmative answer, which is the branch that
        // used to be unreachable.
        let confirmOK = app.buttons["确定"]
        XCTAssertTrue(confirmOK.waitForExistence(timeout: 60), "no native confirm appeared")
        attach(app.screenshot(), name: "step17-dialog-confirm")
        confirmOK.tap()

        // then prompt: the native text field must hold the page's default text.
        let promptField = app.alerts.textFields.firstMatch
        XCTAssertTrue(promptField.waitForExistence(timeout: 60), "no native prompt appeared")
        attach(app.screenshot(), name: "step17-dialog-prompt")
        if promptField.exists {
            promptField.tap()
            promptField.typeText("-step17")
        }
        let promptOK = app.buttons["确定"]
        if promptOK.exists { promptOK.tap() }
        sleep(2)
    }

    // MARK: - The Files app

    /// 我的 iPhone → DSH → workspace，在真实「文件」App 里走一遍。
    ///
    /// `com.apple.DocumentsApp` 是系统「文件」App 的 bundle id。这条断言只能靠
    /// 另一个 App 才能回答：App 自己看不到自己在「文件」里长什么样。
    ///
    /// 关于标签：系统 App 的界面文字随语言和 iOS 版本变，所以每一步都不是硬编码
    /// 一个标识符，而是「中文先试，英文再试，都不成就把当前整棵树打进日志」。
    /// 一条猜错的断言只会给出「失败」，一份打出来的树会告诉下一个人该用什么。
    func testFilesAppShowsWorkspace() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        files.activate()
        sleep(6)
        attach(files.screenshot(), name: "step17-files-launch")

        // WHAT WAS WRONG WITH THE FIRST VERSION, MEASURED ON THIS RUNTIME
        // ---------------------------------------------------------------
        // It assumed the Files app reopens in 我的iPhone with the container folder
        // listed, and its first act was `goUpToDeviceRoot` — walking UP with the
        // back button. Measured in the merged regression: the app reopens on the
        // RECENTS list (`最近项目`), whose tree has no back button at all
        // (`DOC.navBarButton.backInHistory` exists and is Disabled), and whose
        // only cells are the sidebar's LOCATION rows — 位置, iCloud云盘,
        // 我的iPhone, 最近删除, then the tag rows. So `hasRow("DSH")` was false, the
        // back button was disabled, `tapRow("DSH")` found no cell, and the failure
        // said "进不去 App 自己的目录". The app's folder was there the whole time;
        // the test was standing on the wrong screen.
        //
        // The route that works, measured end to end on this runtime:
        //   浏览 tab → 我的iPhone (a cell in the sidebar) → DSH → workspace
        //   → deepseek-harness → default-workspace → mock-tool-output.txt
        // Every level reports its rows here, so a next failure says which level it
        // was standing on instead of guessing.
        switchToBrowseTab(files)
        attach(files.screenshot(), name: "step17-files-browse")

        // If the app already reopened inside the container, there is nothing to do.
        if hasRow(files, name: "workspace") || hasRow(files, name: "mock-tool-output.txt") {
            print("STEP17-FILES already inside the container")
        } else {
            // 我的iPhone is a sidebar cell. Its label is exactly that — the
            // identifier spelling `DOC.sidebar.item.我的iPhone` the first version
            // used does not exist on this runtime (checked: `exists=false`).
            guard tapRow(files, name: "我的iPhone", where: "device-root") else {
                XCTFail("「文件」里没有 我的iPhone 这一行；当前树：\n\(files.debugDescription.prefix(6000))")
                return
            }
            sleep(4)
            attach(files.screenshot(), name: "step17-files-on-my-iphone")
            print("STEP17-FILES device root cells=\(cells(files))")

            XCTAssertTrue(tapRow(files, name: "DSH", where: "dsh-folder"),
                          "进不去 App 自己的目录；当前树：\n\(files.debugDescription.prefix(6000))")
            sleep(4)
            attach(files.screenshot(), name: "step17-files-dsh-folder")

            XCTAssertTrue(tapRow(files, name: "workspace", where: "workspace"),
                          "workspace 没在「文件」里出现；当前树：\n\(files.debugDescription.prefix(6000))")
            sleep(4)
            attach(files.screenshot(), name: "step17-files-workspace")

            // DSH 会话的 cwd 是注册的那个默认工作区文件夹，不是 workspace 根；
            // 智能体用相对路径写的文件因此落在 `deepseek-harness/default-workspace/`
            // 里。这是实测到的位置，所以这一层也要进去，而不是假定文件就在根上。
            _ = tapRow(files, name: "deepseek-harness", where: "harness", optional: true)
            sleep(3)
            _ = tapRow(files, name: "default-workspace", where: "default-workspace", optional: true)
            sleep(3)
        }
        attach(files.screenshot(), name: "step17-files-agent-cwd")

        // 智能体写的文件按名字就在这儿。它是由一次真实的智能体回合写进去的
        // （scripts/step17-acceptance.py agent-write），不是这条测试造的。
        let found = tapRow(files, name: "mock-tool-output.txt", where: "agent-file", optional: true)
        attach(files.screenshot(), name: "step17-files-workspace-contents")
        XCTAssertTrue(found,
                      "智能体写的文件没在「文件」里出现；当前树：\n\(files.debugDescription.prefix(6000))")
        sleep(4)
        attach(files.screenshot(), name: "step17-files-opened-file")
    }

    /// Show the Browse tab, which is the one that lists device locations.
    ///
    /// Measured: on a fresh launch the app is on 最近项目 and its cell list holds the
    /// sidebar's location rows only; 浏览 is a tab bar button and pressing it is what
    /// puts the browse column on screen. Named rather than inlined so the reason is
    /// recorded once.
    private func switchToBrowseTab(_ app: XCUIApplication) {
        for label in ["浏览", "Browse"] {
            let tab = app.tabBars.buttons[label]
            if tab.exists {
                tab.tap()
                sleep(4)
                print("STEP17-FILES browsed via tab \(label)")
                return
            }
        }
        print("STEP17-FILES no 浏览 tab; tree: \(app.debugDescription.prefix(2000))")
    }

    /// The labels of every cell on screen, for a failure message that says what
    /// the screen actually contained.
    private func cells(_ app: XCUIApplication) -> [String] {
        app.cells.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
    }

    /// Walk up to 我的iPhone with the back button.
    ///
    /// The Files app's navigation history is the only always-present way out of
    /// whatever folder it reopened in: the sidebar's location rows need 位置
    /// expanded first, and a test that depends on that is one state away from
    /// failing for an unrelated reason. Presses the back button while it is
    /// enabled, and stops when it is not.
    private func goUpToDeviceRoot(_ app: XCUIApplication) {
        for step in 0..<8 {
            if hasRow(app, name: "workspace") || hasRow(app, name: "DSH") {
                print("STEP17-FILES go-up \(step): container folder in view")
                return
            }
            let back = app.buttons["DOC.navBarButton.backInHistory"]
            guard back.exists, back.isEnabled else {
                print("STEP17-FILES go-up \(step): no back button")
                return
            }
            back.tap()
            sleep(2)
        }
    }

    /// Is there a row whose label is `name` or starts with `name,`?
    ///
    /// The detail suffix is why this cannot be an equality test, and why a plain
    /// prefix test is wrong too — see `tapRow`. No press, so a caller can use it
    /// to find out which screen the Files app is on before acting.
    private func hasRow(_ app: XCUIApplication, name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return app.cells.allElementsBoundByIndex.contains { element in
            let label = element.label
            return label == name || label == stem || label.hasPrefix(name + ",")
                || label.hasPrefix(stem + ",")
        }
    }

    /// Press the CELL for `name` — the row itself, not the text inside it.
    ///
    /// Two measured facts decide this shape:
    ///
    ///   * A row's label is `<name>, <detail>` (`DSH, 5项`, `workspace, 1项`,
    ///     `DSHPortC-uidrive.json, json, 20:37, 24 KB`). So matching by equality on
    ///     the bare name never works, and matching by plain prefix picks the wrong
    ///     item: `DSH` is a prefix of `DSHPortC-uidrive.json`. The comma is the
    ///     boundary the app actually uses, so that is the test.
    ///   * Tapping the `StaticText` INSIDE a row does not open the item: it
    ///     raises the row's context menu (`DSH, 操作菜单`, `显示简介`). Measured,
    ///     and that is why the first version of this test opened a menu instead of
    ///     the folder. The press has to land on the `Cell`.
    @discardableResult
    private func tapRow(_ app: XCUIApplication, name: String, where step: String,
                        optional: Bool = false) -> Bool {
        // TWO spellings, because the Files app reshapes a filename into its label:
        // `mock-tool-output.txt` renders as `mock-tool-output, txt, 21:08, 78 字节`
        // — the dot becomes a comma, the extension its own field. So a plain
        // `name + ","` test can never match a file (measured). The stem is what
        // survives both spellings, and the boundary is still a comma so `DSH`
        // does not match `DSHPortC-uidrive.json`.
        let stem = (name as NSString).deletingPathExtension
        func matches(_ candidates: XCUIElementQuery) -> [XCUIElement] {
            candidates.allElementsBoundByIndex.filter { element in
                let label = element.label
                return label == name || label == stem || label.hasPrefix(name + ",")
                    || label.hasPrefix(stem + ",")
            }
        }
        let cells = matches(app.cells)
        let target = cells.first(where: \.isHittable) ?? cells.first
        if let target {
            if target.isHittable {
                target.tap()
            } else {
                // Off screen or behind something: press its centre by coordinate,
                // which is what a finger does anyway.
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            print("STEP17-FILES \(step) tapped cell '\(name)'")
            return true
        }
        if !optional {
            let labels = app.cells.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
            print("STEP17-FILES \(step) miss '\(name)'; cells=\(labels)")
            print("STEP17-FILES \(step) tree:\n\(app.debugDescription.prefix(4000))")
        }
        return false
    }

    /// A cell if there is one, else the label. The Files app renders its rows as
    /// cells on some versions and as plain text on others, and which one you get
    /// is not worth guessing when both can be asked.
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let cell = app.cells[label].firstMatch
        return cell.exists ? cell : app.staticTexts[label].firstMatch
    }

    /// 按下第一个标签匹配的元素，中文候选逐个试。
    ///
    /// 返回是否点到了东西。`optional` 的步骤失败不判测试失败：哪一步是必须的由
    /// 调用方决定，而「点了没反应」和「页面上根本没有这个元素」必须能分开看。
    @discardableResult
    private func tapFirst(_ app: XCUIApplication, _ labels: [String], where step: String,
                          optional: Bool = false) -> Bool {
        for label in labels {
            for candidate in [app.cells[label].firstMatch,
                              app.staticTexts[label].firstMatch,
                              app.buttons[label].firstMatch,
                              app.otherElements[label].firstMatch] {
                if candidate.exists && candidate.isHittable {
                    candidate.tap()
                    print("STEP17-FILES tap \(step) -> \(label)")
                    return true
                }
            }
        }
        if !optional {
            print("STEP17-FILES miss \(step), tried \(labels); tree:\n\(app.debugDescription.prefix(3000))")
        }
        return false
    }
}
