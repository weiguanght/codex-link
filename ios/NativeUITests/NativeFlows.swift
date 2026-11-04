import XCTest

final class NativeFlows: XCTestCase {
    func testNativeWorkspaceAndConversation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["native.home.create"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.webViews.count, 0)
        capture("Native task home")

        let prompt = app.descendants(matching: .any).matching(identifier: "native.home.prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap(); prompt.typeText("Synthetic home task")
        app.buttons["native.home.create"].tap()
        XCTAssertTrue(app.buttons["native.chat.create"].waitForExistence(timeout: 5))
        app.buttons["native.chat.create"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "消息已提交")).firstMatch.waitForExistence(timeout: 15))

        let composer = app.descendants(matching: .any).matching(identifier: "native.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap(); composer.typeText("Synthetic gesture send")
        app.buttons["native.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "消息已提交")).firstMatch.waitForExistence(timeout: 10))
        capture("Native conversation")

        app.buttons["会话状态与详情"].tap()
        XCTAssertTrue(app.buttons["返回任务列表"].waitForExistence(timeout: 5)); app.buttons["返回任务列表"].tap()

        app.buttons["native.home.settings"].tap()
        capture("Native settings root")
        let model = app.textFields["native.setting.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap(); model.typeText("-draft")
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(model.exists)
        app.buttons["返回"].tap()
        app.buttons["放弃草稿"].tap()
        XCTAssertTrue(app.buttons["native.home.create"].waitForExistence(timeout: 8))

        app.buttons["native.sidebar"].tap()
        XCTAssertTrue(app.buttons["native.newProject"].waitForExistence(timeout: 10))
        app.buttons["native.newProject"].tap()
        let name = app.textFields["native.project.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Native UI Project")
        let path = app.textFields["native.project.path"]
        path.tap()
        path.typeText(try XCTUnwrap(ProcessInfo.processInfo.environment["LINK_SMOKE_PROJECT"]) + "/ui-created")
        app.swipeUp()
        app.switches["目录不存在时创建新文件夹"].tap()
        app.buttons["native.project.save"].tap()
        XCTAssertTrue(app.buttons["native.newChat"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["操作失败"].exists)
        app.swipeDown()
        capture("Native workspace")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
