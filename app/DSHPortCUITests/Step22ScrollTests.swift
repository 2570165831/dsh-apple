//
//  Step22ScrollTests.swift
//  DSHPortCUITests
//
//  A real drag on the transcript and a real tap on a command row, after a turn
//  that ran a command. Reported on the phone: neither did anything.
//

import XCTest

final class Step22ScrollTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = ProcessInfo.processInfo.environment["STEP22_SHOTS"] ?? "/tmp"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(path)/\(name).png"))
    }

    private func labels() -> [(String, CGRect)] {
        app.webViews.firstMatch.descendants(matching: .any).allElementsBoundByIndex.compactMap { element in
            guard element.exists else { return nil }
            let label = element.label
            return label.isEmpty ? nil : (label, element.frame)
        }
    }

    private func dump(_ title: String) {
        print("STEP22 == \(title)")
        for (label, frame) in labels() {
            print("STEP22 \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) \(label.prefix(50))")
        }
    }

    private func drag(fromY: CGFloat, toY: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 200, dy: fromY))
        let end = origin.withOffset(CGVector(dx: 200, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// The labels on screen, top to bottom, as one comparable value.
    private func visible() -> [String] {
        labels().filter { $0.1.minY > 170 && $0.1.minY < 660 }.map { "\(Int($0.1.minY)) \($0.0.prefix(30))" }.sorted()
    }

    private func element(_ text: String) -> XCUIElement {
        app.webViews.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testTranscriptScrollsAndCommandExpands() throws {
        app.launchArguments = ["-DSHPortCTestDrive", "1", "-DSHPortCMockPort", "19716"]
        let steps = (1...12).map { "STEP sh -c 'seq 1 40; echo step22-\($0)'\nDESCRIPTION 第 \($0) 条命令\nTIMEOUTMS 60000" }
        app.launchEnvironment["DSHPORT_UITEST_PROMPT"] = "BASHTEST 滑动验收\n" + steps.joined(separator: "\n")
        app.launchEnvironment["DSHPORT_UITEST_KEYWORD"] = "全部"
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300))
        XCTAssertTrue(element("用时").waitForExistence(timeout: 200), "the turn never finished")
        Thread.sleep(forTimeInterval: 3)
        shot("10-after-turn")

        // 1. The fold row expands. First, because the conversation opens at the
        // bottom, where this row is on screen.
        let fold = element("用时")
        XCTAssertTrue(fold.isHittable, "the fold row is not on screen")
        var before = visible()
        fold.tap()
        Thread.sleep(forTimeInterval: 2)
        var after = visible()
        shot("11-fold-tapped")
        print("STEP22 RESULT fold expanded=\(before != after)")
        XCTAssertNotEqual(before, after, "tapping the fold row changed nothing")

        // 2. The conversation scrolls back towards the top.
        before = visible()
        drag(fromY: 300, toY: 600)
        Thread.sleep(forTimeInterval: 1)
        after = visible()
        shot("12-conversation-dragged")
        print("STEP22 RESULT conversation scrolled=\(before != after)")
        XCTAssertNotEqual(before, after, "dragging did not move the conversation")

        // 3. The trajectory tab scrolls, and a row in it expands.
        element("轨迹").tap()
        Thread.sleep(forTimeInterval: 3)
        shot("13-trajectory")
        before = visible()
        // The list opens at its end, so the only way to go is back up.
        drag(fromY: 300, toY: 600)
        Thread.sleep(forTimeInterval: 1)
        after = visible()
        shot("14-trajectory-dragged")
        print("STEP22 RESULT trajectory scrolled=\(before != after)")
        XCTAssertNotEqual(before, after, "dragging did not move the trajectory")

        // 4. A row in it opens.
        let row = element("第 11 条命令")
        before = visible()
        row.tap()
        Thread.sleep(forTimeInterval: 2)
        after = visible()
        shot("15-trajectory-row-tapped")
        print("STEP22 RESULT trajectory row expanded=\(before != after)")
        XCTAssertNotEqual(before, after, "tapping a trajectory row changed nothing")

        // 5. The right bar still opens over the page, and closing it gives the page back.
        element("打开右侧边栏").tap()
        Thread.sleep(forTimeInterval: 2)
        shot("16-right-bar-open")
        let close = element("收起右侧边栏")
        XCTAssertTrue(close.exists, "the right bar did not open")
        close.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("17-right-bar-closed")
        // The trajectory's detail panel from step 4 is still open and does not
        // scroll, so the check goes to the conversation.
        // Exact: the composer's placeholder also contains this word.
        app.webViews.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "对话")).firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        before = visible()
        drag(fromY: 600, toY: 300)
        Thread.sleep(forTimeInterval: 1)
        after = visible()
        print("STEP22 RESULT scrolls after closing the right bar=\(before != after)")
        XCTAssertNotEqual(before, after, "the page did not come back after closing the right bar")
    }

    /// A launch with no mock argument, which is what the phone does. Every other test
    /// passes the argument, so nothing else sees this configuration.
    ///
    /// The keys are made up. Saving one sends nothing anywhere, and no turn is run.
    func testNormalLaunchOffersRealProviders() throws {
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300))
        Thread.sleep(forTimeInterval: 12)
        shot("20-normal-launch")
        XCTAssertTrue(element("添加 API Key").exists, "a launch with no key should offer to add one")
        element("稍后配置").exists ? () : element("添加 API Key").tap()
        Thread.sleep(forTimeInterval: 3)
        element("稍后配置").tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(element("Mock").exists, "a normal launch must not offer the mock")

        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: 437)).tap()
        Thread.sleep(forTimeInterval: 2)
        element("账号菜单").tap()
        Thread.sleep(forTimeInterval: 2)
        element("设置").tap()
        Thread.sleep(forTimeInterval: 3)
        app.webViews.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "模型")).firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        element("添加模型提供商").tap()
        Thread.sleep(forTimeInterval: 3)

        // The tree lists the DeepSeek row's field and button after the new provider's.
        let web = app.webViews.firstMatch
        web.secureTextFields.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        web.secureTextFields.element(boundBy: 0).typeText("step22-not-a-real-key")
        Thread.sleep(forTimeInterval: 1)
        let saves = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "保存"))
        saves.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 4)
        shot("21-third-party-saved")
        dump("after third-party save")
        XCTAssertTrue(element("已保存").exists, "saving a third-party provider reported nothing")
        print("STEP22 RESULT save message=\(element("已保存").label)")

        // The route most phones use: a DeepSeek key must leave the default model usable.
        element("编辑").tap()
        Thread.sleep(forTimeInterval: 3)
        web.secureTextFields.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        web.secureTextFields.element(boundBy: 0).typeText("step22-not-a-real-key")
        Thread.sleep(forTimeInterval: 1)
        saves.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 4)
        shot("21b-deepseek-saved")
        dump("after deepseek save")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 300))
        Thread.sleep(forTimeInterval: 12)
        shot("22-relaunched")
        // Only a third-party key is saved, so DSH's own first-run prompt is still up.
        let dismiss = app.webViews.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "关闭")).firstMatch
        if dismiss.exists { dismiss.tap(); Thread.sleep(forTimeInterval: 2) }
        let picker = element("模型")
        print("STEP22 RESULT picker after relaunch=\(picker.label)")
        shot("22b-model-button")
        XCTAssertFalse(app.webViews.firstMatch.staticTexts["1017"].exists,
                       "the release tag is still inside the model button")
        picker.tap()
        Thread.sleep(forTimeInterval: 3)
        shot("23-picker-open")
        dump("picker open")
        XCTAssertFalse(element("Mock").exists, "the mock came back after a relaunch")
        XCTAssertFalse(picker.label.contains("请选择模型"), "a saved DeepSeek key left no model selected")
        XCTAssertTrue(element("DeepSeek").exists || element("deepseek").exists,
                      "the saved DeepSeek route is not in the picker after a relaunch")
        // The models live one level down, under the 模型 row of the menu.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 201, dy: 459)).tap()
        Thread.sleep(forTimeInterval: 3)
        shot("24-model-list")
        dump("model list")
        // Settings saves into the profile's own patch file, which the app used to rewrite.
        XCTAssertTrue(element("amazon").exists || element("Bedrock").exists || element("Amazon").exists,
                      "the saved third-party provider did not survive a relaunch")
    }
}
