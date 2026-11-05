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
        XCTAssertTrue(app.staticTexts["代码差异"].firstMatch.waitForExistence(timeout: 5))
        capture("Native conversation with wrapped diff")

        composer.tap(); composer.typeText("Synthetic scroll regression")
        app.buttons["native.send"].tap()
        XCTAssertTrue(app.staticTexts["History reading baseline"].waitForExistence(timeout: 10))
        let transcript = app.scrollViews["native.transcript"]
        XCTAssertTrue(transcript.exists)
        for _ in 0..<4 { transcript.swipeDown() }
        let history = try XCTUnwrap(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History entry")).allElementsBoundByIndex.first { $0.isHittable })
        let historyLabel = history.label
        let historyY = history.frame.minY
        // Cross several empty polls, then an appended reply and a streamed text update.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(history.isHittable)
        XCTAssertEqual(history.frame.minY, historyY, accuracy: 12, "Empty polling moved the reading position")
        Thread.sleep(forTimeInterval: 22)
        let retained = app.staticTexts.matching(NSPredicate(format: "label == %@", historyLabel)).firstMatch
        XCTAssertTrue(retained.isHittable)
        XCTAssertEqual(retained.frame.minY, historyY, accuracy: 12, "Incoming content interrupted history reading")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", historyLabel)).firstMatch.waitForExistence(timeout: 10))
        let resumedHistory = app.staticTexts.matching(NSPredicate(format: "label == %@", historyLabel)).firstMatch
        XCTAssertTrue(resumedHistory.isHittable)
        XCTAssertEqual(resumedHistory.frame.minY, historyY, accuracy: 12, "Foreground refresh reset the transcript position")
        capture("History position retained across polls and incoming content")
        let edgeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let edgeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeEnd)
        XCTAssertTrue(app.buttons["native.home.create"].waitForExistence(timeout: 5), "Left-edge swipe did not return to the task home")
        let selectedSession = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(selectedSession.waitForExistence(timeout: 8))
        selectedSession.tap()
        XCTAssertTrue(app.staticTexts["History reading baseline"].waitForExistence(timeout: 8))
        app.buttons["回到最新消息"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic background update complete"].waitForExistence(timeout: 8))

        app.buttons["native.thread.settings"].tap()
        let effort = app.buttons["native.thread.effort"]
        XCTAssertTrue(effort.waitForExistence(timeout: 8))
        effort.tap(); app.buttons["low"].tap()
        app.buttons["native.thread.model"].tap(); app.buttons["Synthetic Restricted"].tap()
        effort.tap()
        XCTAssertTrue(app.buttons["minimal"].exists)
        XCTAssertFalse(app.buttons["low"].exists)
        app.buttons["minimal"].tap()
        capture("Reasoning dropdown follows selected model")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["native.thread.settings"].waitForExistence(timeout: 8))
        let savedEffort = NSPredicate(format: "label CONTAINS %@", "minimal")
        expectation(for: savedEffort, evaluatedWith: app.buttons["native.thread.settings"])
        waitForExpectations(timeout: 8)
        app.buttons["native.thread.settings"].tap()
        XCTAssertTrue(effort.waitForExistence(timeout: 8))
        XCTAssertTrue(effort.label.contains("minimal"))
        app.buttons["取消"].tap()

        composer.tap(); composer.typeText("Retained workspace draft")
        app.buttons["native.workspace.open"].tap()
        let search = app.textFields["native.workspace.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap(); search.typeText("example.swift")
        let file = app.buttons["native.workspace.entry.Sources/example.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 8)); file.tap()
        let preview = app.descendants(matching: .any).matching(identifier: "native.workspace.editor").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue((preview.value as? String)?.contains("workspaceValue = \"working\"") == true)
        app.buttons["native.workspace.edit"].tap()
        let codeEditor = app.descendants(matching: .any).matching(identifier: "native.workspace.editor").firstMatch
        XCTAssertTrue(codeEditor.waitForExistence(timeout: 8))
        XCTAssertTrue((codeEditor.value as? String)?.contains("workspaceValue") == true)
        codeEditor.tap(); codeEditor.typeText("\n// Native editor save")
        app.buttons["native.workspace.save"].tap()
        XCTAssertTrue(app.staticTexts["native.workspace.save.status"].waitForExistence(timeout: 8))
        app.buttons["返回"].tap()
        app.buttons["将路径带回输入框"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        XCTAssertTrue((composer.value as? String)?.contains("Retained workspace draft\n\nSources/example.swift") == true)
        app.buttons["native.workspace.open"].tap()
        XCTAssertTrue(app.buttons["变更"].waitForExistence(timeout: 8)); app.buttons["变更"].tap()
        app.buttons["已暂存"].tap()
        let change = app.buttons["native.workspace.change.Sources/example.swift"]
        XCTAssertTrue(change.waitForExistence(timeout: 8)); change.tap()
        XCTAssertTrue(app.staticTexts["代码差异"].waitForExistence(timeout: 8))
        capture("Native staged workspace diff")
        app.buttons["评论此文件"].tap()
        let comment = app.textViews["native.diff.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5)); comment.tap(); comment.typeText("Please review this change")
        app.buttons["native.diff.comment.insert"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        let composed = composer.value as? String ?? ""
        XCTAssertTrue(composed.contains("Retained workspace draft") && composed.contains("Please review this change"))
        capture("Workspace comment appended to existing draft")

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
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "FAIL:")).firstMatch.exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
