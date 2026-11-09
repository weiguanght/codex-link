import XCTest

final class NativeFlows: XCTestCase {
    private func openChatMenu(_ app: XCUIApplication) {
        let menu = app.buttons["native.chat.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["native.workspace.open"].waitForExistence(timeout: 5))
    }

    func testChatMenuContextAndSendHold() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-native.followUpBehavior", "send"]
        app.launch()
        let session = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(session.waitForExistence(timeout: 40)); session.tap()
        let field = app.descendants(matching: .any).matching(identifier: "native.composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let contextLoaded = NSPredicate(format: "placeholderValue == %@", "24K / 128K（18.8%）")
        expectation(for: contextLoaded, evaluatedWith: field)
        waitForExpectations(timeout: 10)
        app.buttons["会话状态与详情"].tap()
        XCTAssertTrue(app.navigationBars["会话详情"].waitForExistence(timeout: 5))
        capture("Context K/M counts and API reference session cost")
        app.buttons["完成"].tap()
        let emptyDraft = NSPredicate { _, _ in
            let value = field.value as? String ?? ""
            return value.isEmpty || value == field.placeholderValue
        }
        XCTAssertFalse(app.buttons["native.workspace.open"].exists)
        XCTAssertFalse(app.buttons["native.thread.settings"].exists)
        openChatMenu(app)
        let workspace = app.buttons["native.workspace.open"]
        XCTAssertGreaterThan(workspace.frame.width, 0)
        XCTAssertLessThan(workspace.frame.width, app.frame.width)
        capture("System-width chat menu matching native conversation actions")
        XCTAssertTrue(app.buttons["native.thread.settings"].exists)
        app.buttons["native.send.settings"].tap()
        XCTAssertTrue(app.navigationBars["消息发送设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        field.tap(); field.typeText("Synthetic long press send")
        let send = app.buttons["native.send"]
        send.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["native.send.once.queue"].waitForExistence(timeout: 5))
        capture("One-off sending options from a long press")
        let chooserHeader = app.staticTexts["本次发送方式"]
        let header = chooserHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        header.press(forDuration: 0.05, thenDragTo: header.withOffset(CGVector(dx: 0, dy: 180)))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String ?? "").contains("Synthetic long press send"), "Holding or dismissing the send chooser submitted the draft")
        send.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["native.send.once.queue"].waitForExistence(timeout: 5))
        app.buttons["native.send.once.queue"].tap()
        expectation(for: emptyDraft, evaluatedWith: field)
        waitForExpectations(timeout: 8)
        field.tap(); field.typeText("Synthetic default tap send")
        send.tap()
        expectation(for: emptyDraft, evaluatedWith: field)
        waitForExpectations(timeout: 8)
        openChatMenu(app)
        app.buttons["native.thread.settings"].tap()
        XCTAssertTrue(app.navigationBars["模型与推理"].waitForExistence(timeout: 8))
        app.buttons["取消"].tap()
        openChatMenu(app); workspace.tap()
        XCTAssertTrue(app.textFields["native.workspace.search"].waitForExistence(timeout: 8))
        capture("Workspace reached through the native chat menu")
    }

    func testOpenSessionsAndInteractiveBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let desktop = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 40))
        let readOnlyMenu = app.buttons["native.session.actions.00000000-0000-0000-0000-000000000001"]
        readOnlyMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["永久删除…"].waitForExistence(timeout: 5))
        app.buttons["永久删除…"].tap()
        XCTAssertTrue(app.staticTexts["永久删除此会话？"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        for _ in 0..<3 {
            desktop.tap()
            XCTAssertTrue(app.scrollViews["native.transcript"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["native.chat.back"].waitForExistence(timeout: 5))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertTrue(app.buttons["native.chat.back"].exists, "A slow swipe below 38% should cancel")
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(desktop.waitForExistence(timeout: 5), "A swipe over 38% should return")
        }
        app.buttons["native.home.session.00000000-0000-0000-0000-000000000001"].tap()
        XCTAssertTrue(app.buttons["native.chat.back"].waitForExistence(timeout: 10))
        app.buttons["native.chat.back"].tap()
        XCTAssertTrue(desktop.waitForExistence(timeout: 5))
        capture("Repeated desktop and read-only session opening and interactive back")
    }

    func testAutomaticHistoryAndRepositorySelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let session = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(session.waitForExistence(timeout: 40)); session.tap()
        let transcript = app.scrollViews["native.transcript"]
        let change = app.buttons["native.tool.f1"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        for _ in 0..<6 { if change.isHittable { break }; transcript.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.tool.f1.stats").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(change.label.contains("+2") && change.label.contains("−2"), change.label)
        capture("Chat file change row with colored complete stats")
        change.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.tool.detail.stats").firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["apps/client/"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sources/example.swift"].exists)
        XCTAssertFalse(app.staticTexts["apps/client/Sources/example.swift"].exists)
        capture("File change stats and shared directory prefix")
        app.buttons["完成"].tap()
        openChatMenu(app)
        app.buttons["native.workspace.open"].tap()
        XCTAssertTrue(app.buttons["变更"].waitForExistence(timeout: 8)); app.buttons["变更"].tap()
        let repository = app.buttons["native.workspace.repository"]
        XCTAssertTrue(repository.waitForExistence(timeout: 8))
        repository.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        app.buttons["apps/tools/worker"].tap()
        let nested = app.buttons["native.workspace.change.apps/tools/worker/tracked.txt"]
        XCTAssertTrue(nested.waitForExistence(timeout: 8))
        XCTAssertTrue(nested.label.contains("+1") && nested.label.contains("−1"), nested.label)
        capture("Third-level repository selected with colored file stats")
        nested.tap()
        XCTAssertTrue(app.staticTexts["working nested"].waitForExistence(timeout: 8))
        capture("Selected nested repository patch")
        app.buttons["返回"].tap()
        app.buttons["完成"].tap()

        verifySilentHistoryPrefetch(app: app, transcript: transcript)
    }

    func testSilentHistoryPrefetch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let session = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(session.waitForExistence(timeout: 40)); session.tap()
        let transcript = app.scrollViews["native.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        verifySilentHistoryPrefetch(app: app, transcript: transcript)
    }

    private func verifySilentHistoryPrefetch(app: XCUIApplication, transcript: XCUIElement) {
        let composer = app.descendants(matching: .any).matching(identifier: "native.composer").firstMatch
        composer.tap(); composer.typeText("Synthetic pagination regression")
        app.buttons["native.send"].tap()
        let history = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto history 35:")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        let previous = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto history 06:")).firstMatch
        // Idle/poll-driven layouts may not fetch history; short user scrolls do.
        XCTAssertFalse(previous.exists, "History was fetched without user scrolling")
        for _ in 0..<45 {
            if previous.exists { break }
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)))
        }
        XCTAssertTrue(previous.waitForExistence(timeout: 8), "Near-top short scroll did not silently prefetch")
        XCTAssertFalse(app.buttons["更早的消息"].exists)
        capture("Older page loaded automatically and reading anchor retained")
        for _ in 0..<12 {
            if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto history 00:")).firstMatch.exists { break }
            scrollTowardHistory(app: app, transcript: transcript)
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto history 00:")).firstMatch.waitForExistence(timeout: 8), "Second automatic page did not load")
        capture("Automatic history reaches the first message")
    }

    func testToolDetailsAndWrapping() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let session = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(session.waitForExistence(timeout: 40)); session.tap()
        let transcript = app.scrollViews["native.transcript"]
        let command = app.buttons["native.tool.t1"]
        XCTAssertTrue(command.waitForExistence(timeout: 10))
        for _ in 0..<6 { if command.isHittable { break }; transcript.swipeDown() }
        XCTAssertTrue(command.isHittable)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Synthetic tool output")).firstMatch.exists)
        capture("Compact command rows without output")
        command.tap()
        XCTAssertTrue(app.navigationBars["执行命令"].waitForExistence(timeout: 8))
        let input = app.staticTexts["native.tool.detail.input"]
        let output = app.staticTexts["native.tool.detail.output"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertTrue(input.label.contains("rg --files ios/CodexLink"))
        XCTAssertTrue(output.waitForExistence(timeout: 8))
        let complete = NSPredicate(format: "label CONTAINS %@", "Synthetic output final page")
        expectation(for: complete, evaluatedWith: output)
        waitForExpectations(timeout: 15)
        XCTAssertLessThan(input.frame.minY, output.frame.minY, "Full command must appear above its output")
        capture("Single command detail with paginated output")
        app.buttons["详情选项"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["自动换行"].tap()
        capture("Command output with horizontal scrolling")
        app.buttons["完成"].tap()
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Synthetic tool output")).firstMatch.exists)

        app.buttons["native.tool.t2"].tap()
        XCTAssertTrue(app.navigationBars["执行命令"].waitForExistence(timeout: 5))
        let secondInput = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "echo second-command")).firstMatch
        let secondOutput = app.staticTexts["Synthetic second output"]
        XCTAssertTrue(secondInput.waitForExistence(timeout: 8))
        XCTAssertTrue(secondOutput.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Synthetic tool output")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "exit 17")).firstMatch.exists)
        app.buttons["完成"].tap()

        app.buttons["native.tool.f1"].tap()
        XCTAssertTrue(app.navigationBars["文件变更"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sources/example.swift"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.diff.commonDirectory").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.diff.line.0.1").firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "@@")).firstMatch.exists)
        capture("Rendered file changes in a standalone sheet")
        app.buttons["完成"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        XCTAssertTrue(app.buttons["native.home.settings"].waitForExistence(timeout: 8))
        app.buttons["native.home.settings"].tap()
        let wrapping = app.switches["native.settings.commandWrapping"]
        XCTAssertTrue(wrapping.waitForExistence(timeout: 8))
        for _ in 0..<4 { if wrapping.exists && wrapping.frame.maxY < app.frame.maxY - 80 { break }; app.swipeUp() }
        XCTAssertEqual(wrapping.value as? String, "0", "Detail toggle must share the saved setting")
        wrapping.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: wrapping)
        waitForExpectations(timeout: 8)
        capture("Command wrapping setting")
        app.buttons["完成"].tap()
    }

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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "代码差异")).firstMatch.waitForExistence(timeout: 5))
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
        if app.buttons["回到最新消息"].exists { app.buttons["回到最新消息"].tap() }
        XCTAssertTrue(app.staticTexts["Synthetic background update complete"].waitForExistence(timeout: 8))

        openChatMenu(app)
        app.buttons["native.thread.settings"].tap()
        let effort = app.buttons["native.thread.effort"]
        XCTAssertTrue(effort.waitForExistence(timeout: 8))
        effort.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap(); app.buttons["low"].tap()
        app.buttons["native.thread.model"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap(); app.buttons["Synthetic Restricted"].tap()
        effort.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["minimal"].exists)
        XCTAssertFalse(app.buttons["low"].exists)
        app.buttons["minimal"].tap()
        capture("Reasoning dropdown follows selected model")
        app.buttons["保存"].tap()
        openChatMenu(app)
        app.buttons["native.thread.settings"].tap()
        XCTAssertTrue(effort.waitForExistence(timeout: 8))
        XCTAssertTrue(effort.label.contains("minimal"))
        app.buttons["取消"].tap()

        let attachmentMenu = app.buttons["native.attachment.menu"]
        XCTAssertTrue(attachmentMenu.exists)
        attachmentMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["选择照片"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["拍照"].exists)
        XCTAssertTrue(app.buttons["选择文件"].exists)
        attachmentMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        composer.tap(); composer.typeText("Retained workspace draft")
        openChatMenu(app)
        app.buttons["native.workspace.open"].tap()
        let search = app.textFields["native.workspace.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native.workspace.search.icon").firstMatch.exists)
        XCTAssertTrue(app.buttons["工作区"].exists)
        app.buttons["native.workspace.fileMenu"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["刷新"].exists)
        XCTAssertTrue(app.buttons["导入文件"].exists)
        XCTAssertTrue(app.buttons["排序"].exists)
        app.buttons["刷新"].tap()
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
        openChatMenu(app)
        app.buttons["native.workspace.open"].tap()
        XCTAssertTrue(app.buttons["变更"].waitForExistence(timeout: 8)); app.buttons["变更"].tap()
        app.buttons["已暂存"].tap()
        let change = app.buttons["native.workspace.change.Sources/example.swift"]
        XCTAssertTrue(change.waitForExistence(timeout: 8)); change.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "代码差异")).firstMatch.waitForExistence(timeout: 8))
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
        XCTAssertTrue(app.staticTexts["Token 用量与费用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["返回任务列表"].waitForExistence(timeout: 5)); app.buttons["返回任务列表"].tap()

        app.buttons["native.home.settings"].tap()
        capture("Native settings root")
        app.buttons["默认行为"].tap()
        let model = app.textFields["native.setting.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap(); model.typeText("-draft")
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(model.exists)
        app.buttons["返回"].tap()
        app.buttons["放弃草稿"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 8)); app.buttons["完成"].tap()
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

    func testSessionOperations() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let identifier = "00000000-0000-0000-0000-000000000002"
        let session = app.buttons["native.home.session." + identifier]
        let actions = app.buttons["native.session.actions." + identifier]
        XCTAssertTrue(session.waitForExistence(timeout: 40))
        actions.tap()
        XCTAssertTrue(app.buttons["重命名"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["永久删除…"].exists)
        app.buttons["置顶"].tap()
        actions.tap()
        XCTAssertTrue(app.buttons["取消置顶"].waitForExistence(timeout: 5))
        app.buttons["标为未读"].tap()
        session.tap()
        XCTAssertTrue(app.scrollViews["native.transcript"].waitForExistence(timeout: 10))
        let toolbarActions = app.buttons["native.session.actions." + identifier]
        openChatMenu(app)
        XCTAssertTrue(toolbarActions.waitForExistence(timeout: 5))
        toolbarActions.tap()
        XCTAssertTrue(app.buttons["标为未读"].waitForExistence(timeout: 5), "Opening the chat must clear its unread marker")
        app.buttons["重命名"].tap()
        let name = app.textFields["对话名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" updated")
        app.buttons["保存"].tap()
        if !toolbarActions.exists { openChatMenu(app) }
        XCTAssertTrue(toolbarActions.waitForExistence(timeout: 5))
        toolbarActions.tap()
        app.buttons["复制"].tap()
        XCTAssertTrue(app.buttons["复制深层链接"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["复制为 Markdown"].exists)
        XCTAssertTrue(app.buttons["复制工作目录"].exists)
        app.buttons["复制工作目录"].tap()
        toolbarActions.tap()
        app.buttons["永久删除…"].tap()
        XCTAssertTrue(app.staticTexts["永久删除此会话？"].waitForExistence(timeout: 5))
        capture("Permanent delete requires an explicit confirmation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.scrollViews["native.transcript"].exists)
        XCTAssertFalse(app.alerts["操作失败"].exists)
        XCTAssertTrue(app.buttons["native.chat.back"].exists)
        app.buttons["native.chat.back"].tap()
        XCTAssertTrue(app.buttons["native.home.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["你的工作空间"].exists)
    }

    func testMessageTablesFilePreviewsAndToolbar() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "local.codex.link")
        for key in ["PORT", "PIN", "ID"] {
            let name = "LINK_SMOKE_" + key
            app.launchEnvironment[name] = ProcessInfo.processInfo.environment[name]
        }
        app.launchEnvironment["LINK_SMOKE_UI"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let session = app.buttons["native.home.session.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(session.waitForExistence(timeout: 40)); session.tap()
        let transcript = app.scrollViews["native.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let table = app.scrollViews["native.markdown.table"].firstMatch
        for _ in 0..<8 { if table.isHittable { break }; transcript.swipeUp() }
        XCTAssertTrue(table.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Native table"].exists)
        capture("Native rendered Markdown table")
        let disclosure = app.descendants(matching: .any).matching(identifier: "native.chat.files").firstMatch
        for _ in 0..<8 { if disclosure.isHittable { break }; transcript.swipeUp() }
        XCTAssertTrue(disclosure.isHittable); disclosure.tap()
        let short = app.buttons["native.chat.file.short.txt"]
        let longest = app.buttons["native.chat.file.longest-conversation-document.md"]
        for _ in 0..<5 {
            if short.isHittable && short.frame.maxY < app.buttons["native.attachment.menu"].frame.minY - 12 { break }
            transcript.swipeUp()
        }
        XCTAssertTrue(short.exists && longest.isHittable, app.debugDescription)
        XCTAssertEqual(short.frame.minX, longest.frame.minX, accuracy: 2)
        XCTAssertEqual(short.frame.width, longest.frame.width, accuracy: 2)
        capture("Conversation files share a centered leading-aligned column")
        short.tap()
        XCTAssertTrue(app.descendants(matching: .any)["native.file.preview.text"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["完成"].exists)
        app.buttons["native.file.preview.menu"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["系统文件打开"].waitForExistence(timeout: 5))
        app.buttons["系统文件打开"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5), app.debugDescription)
        // Dismiss the activity sheet, then verify its completion kept the preview file.
        app.swipeDown()
        let done = app.navigationBars.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let markdown = app.buttons["native.chat.file.longest-conversation-document.md"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 5)); markdown.tap()
        XCTAssertTrue(app.scrollViews["native.file.preview.markdown"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["native.markdown.table"].firstMatch.exists)
        app.navigationBars.buttons["完成"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let image = app.buttons["native.chat.file.image.png"]
        for _ in 0..<4 { if image.isHittable { break }; transcript.swipeUp() }
        image.tap()
        XCTAssertTrue(app.descendants(matching: .any)["native.file.preview.image"].waitForExistence(timeout: 10))
        app.buttons["native.file.preview.menu"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["保存到相册"].waitForExistence(timeout: 5))
        capture("Image preview with Save to Photos and system open actions")
        // Choosing system open dismisses the menu without touching the photo library.
        app.buttons["系统文件打开"].tap(); app.swipeDown()
        app.navigationBars.buttons["完成"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        openChatMenu(app)
        app.buttons["native.workspace.open"].tap()
        let menu = app.buttons["native.workspace.fileMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        let search = app.textFields["native.workspace.search"]
        XCTAssertTrue(search.exists)
        XCTAssertLessThan(menu.frame.midY, search.frame.minY)
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["刷新"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导入文件"].exists)
        capture("Workspace actions moved to the top-right toolbar")
    }

    private func scrollTowardHistory(app: XCUIApplication, transcript: XCUIElement) {
        let top = max(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY) + 24
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width / 2, dy: top))
        let end = start.withOffset(CGVector(dx: 0, dy: 90))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
