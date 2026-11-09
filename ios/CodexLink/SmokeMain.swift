// Test entry point exists only in a LINK_SMOKE simulator build.
#if LINK_SMOKE
import SwiftUI

@main
struct SmokeMain: App {
    @StateObject private var smoke = NativeSmoke()
    var body: some Scene {
        WindowGroup {
            NativeSmokeScreen(smoke: smoke).task { await smoke.run() }
        }
    }
}
struct NativeSmokeScreen: View {
    @ObservedObject var smoke: NativeSmoke
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var chat: ChatModel
    init(smoke: NativeSmoke) { self.smoke = smoke; workspace = smoke.workspace; chat = smoke.chat }
    @State private var sidebar = false
    @State private var create = false
    @State private var settings = false
    @StateObject private var connection = Connection()
    @State private var initialPrompt = ""
    var body: some View {
        NavigationStack {
            NativeChatView(chat: smoke.chat, workspace: smoke.workspace, onSidebar: { sidebar = true }, onHome: { smoke.workspace.selected = nil; smoke.workspace.selectProject(nil) }, onNewChat: { prompt in initialPrompt = prompt; create = true }, onSettings: { settings = true })
                .overlay(alignment: .top) { if smoke.result.hasPrefix("FAIL") { Text(smoke.result).font(.caption).foregroundStyle(.red).padding().background(.regularMaterial) } }
                .sheet(isPresented: $sidebar) { NavigationStack { NativeLibraryView(model: smoke.workspace, onSelect: { smoke.workspace.selected = $0; sidebar = false }, onNewChat: { sidebar = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { create = true } }, onSettings: { sidebar = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settings = true } }) } }
                .sheet(isPresented: $create) { NativeNewChat(model: smoke.workspace, initialPrompt: initialPrompt) { row in smoke.chat.primeDraft(initialPrompt, for: row); smoke.workspace.selected = row; initialPrompt = "" } }
                .sheet(isPresented: $settings) { NavigationStack { NativeAppSettings(connection: connection, workspace: smoke.workspace) } }
        }
        .task(id: smoke.workspace.filterID) { if smoke.api.ready { await smoke.workspace.load() } }
        .task(id: smoke.workspace.selected?.identity ?? "none") { if smoke.api.ready { await smoke.chat.run(smoke.workspace.selected) } }
    }
}
@MainActor
final class NativeSmoke: ObservableObject {
    let api: NativeAPI
    let workspace: WorkspaceModel
    let chat: ChatModel
    @Published var result = "Testing…"
    init() { let api = NativeAPI(); self.api = api; workspace = WorkspaceModel(api: api); chat = ChatModel(api: api) }
    func require(_ value: Bool, _ message: String) throws { if !value { throw LinkError.message(message) } }
    private func verifyShellCommandSummary() throws {
        let commands: [(String, String)] = [
            (#"/bin/zsh -lc "git status --short""#, "git status --short"),
            (#"bash -c 'git status --short'"#, "git status --short"),
            (#"/bin/bash --noprofile --norc -l -c "echo \"quoted\"; printf '%s\n' 中文""#, #"echo "quoted"; printf '%s\n' 中文"#),
            (#"sh -c 'printf '\''hello'\'''"#, "printf 'hello'"),
            ("/bin/zsh -lc \"git status --short\nrg -n '代码差异|默认行为|native.settings.commandWrapping' ios/NativeUITests/NativeFlows.swift\"", "git status --short\nrg -n '代码差异|默认行为|native.settings.commandWrapping' ios/NativeUITests/NativeFlows.swift"),
            ("git status --short", "git status --short"),
            (#"printf '%s\n' "/bin/zsh -lc""#, #"printf '%s\n' "/bin/zsh -lc""#),
            (#"zsh -c echo"#, #"zsh -c echo"#),
            (#"/bin/zsh -lc "echo hi"; echo outside"#, #"/bin/zsh -lc "echo hi"; echo outside"#),
            (#"/bin/zsh -lc "echo hi" shell-name"#, #"/bin/zsh -lc "echo hi" shell-name"#),
            (#"/bin/zsh -lc "incomplete"#, #"/bin/zsh -lc "incomplete"#),
        ]
        for (source, expected) in commands {
            try require(NativeShellCommand.display(source) == expected, "Shell command summary changed content: " + source)
        }
        try require(NativeShellCommand.display(#"/bin/zsh -lc "incomplete"#, allowIncomplete: true) == "incomplete", "Truncated shell preview kept its wrapper")
    }
    private func verifyToolRendering() throws {
        try verifyShellCommandSummary()
        let diff = NativeDiffDocument("""
        Sources/中文 文件.swift
        @@ -10,2 +20,3 @@ func example
        -let old = 1
        +let new = 2
         let same = 3
        +let extra = 4

        README.md
        @@ -1 +1 @@
        -old
        +new
        """)
        try require(diff.files.count == 2 && diff.files[0].path == "Sources/中文 文件.swift", "Flattened desktop file sections were lost")
        try require(diff.files[0].additions == 2 && diff.files[0].deletions == 1, "Diff stats are incorrect")
        try require(diff.files[0].lines[1].old == 10 && diff.files[0].lines[2].new == 20 && diff.files[0].lines[3].old == 11, "Hunk line positions are incorrect")
        let shared = NativeDiffDocument("/workspace/project/Sources/main.swift\n@@ -1 +1 @@\n-old\n+new\n\n/workspace/project/Tests/main.swift\n@@ -1 +1 @@\n-before\n+after")
        try require(shared.commonDirectory == "/workspace/project/", "Diff common directory is incorrect")
        try require(NativeDiffDocument("Sources/main.swift\n@@ -1 +1 @@\n-old\n+new").commonDirectory == "Sources/", "Single-file directory did not collapse")
        try require(diff.commonDirectory.isEmpty, "Unrelated paths gained an incorrect common prefix")
        let prefixes = NativeDiffDocument("--- a/test.txt\n+++ b/test.txt\n@@ -1 +1 @@\n---deleted\n+++added")
        try require(prefixes.files.count == 1 && prefixes.files[0].additions == 1 && prefixes.files[0].deletions == 1, "Code prefixes became file headers")
        let patch = NativeDiffDocument("*** Begin Patch\n*** Add File: new.py\n+print(1)\n*** Update File: old.py\n*** Move to: renamed.py\n@@\n-old\n+new\n*** End Patch")
        try require(patch.files.count == 2 && patch.files[0].lines.first?.new == 1 && patch.files[1].path == "renamed.py" && patch.files[1].previousPath == "old.py", "apply_patch file/move parsing failed")
        let removed = NativeDiffDocument("diff --git a/old.txt b/old.txt\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone")
        try require(removed.files.first?.path == "old.txt" && removed.files.first?.deletions == 1, "Deleted file was lost")
        let added = NativeDiffDocument("new.txt\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+new")
        try require(added.files.count == 1 && added.files[0].path == "new.txt" && added.files[0].additions == 1, "Git metadata created a phantom file")
        let large = NativeDiffDocument("large.txt\n@@ -0,0 +1,2100 @@\n" + Array(repeating: "+value", count: 2100).joined(separator: "\n"))
        try require(large.files.first?.additions == 2100, "Large diffs stopped being structured")
        let command = "printf '中文👨‍👩‍👧‍👦'\n\nprintf done"
        let data = try JSONSerialization.data(withJSONObject: ["key": "test", "order": 0, "role": "activity", "kind": "commandExecution", "text": command, "version": "v1", "inputLength": command.unicodeScalars.count])
        let row = try JSONDecoder().decode(NativeRow.self, from: data)
        let presentation = NativeToolPresentation(row: row, text: command + "\n\nresult")
        try require(presentation.input == command && presentation.output == "result", "Unicode/multiline command was split into output")
        let highlighted = NativeSyntaxHighlight.text("let value = 42", language: "swift")
        try require(String(highlighted.characters) == "let value = 42" && highlighted.runs.count > 1, "Syntax highlighting lost source or colors")
    }
    private func verifyMessageContent() throws {
        try require(!NativeBackNavigation.shouldFinish(progress: 0.37, velocity: 0), "Short back swipe must cancel")
        try require(NativeBackNavigation.shouldFinish(progress: 0.38, velocity: 0), "38 percent back swipe must finish")
        try require(NativeBackNavigation.shouldFinish(progress: 0.1, velocity: 900), "Right fling must finish")
        try require(!NativeBackNavigation.shouldFinish(progress: 0.1, velocity: -900), "Left fling must not finish")
        let rows = ["| 文件 | 状态 | 数量 |", "| :--- | :---: | ---: |", "| **代码** | 已完成 | 12 |", "| a\\|b | `left|right` | 3 |", ""]
        let table = NativeMarkdownTable.parse(rows, at: 0)?.table
        try require(table?.headers == ["文件", "状态", "数量"], "Markdown table headers were lost")
        try require(table?.alignments == [.leading, .center, .trailing], "Markdown table alignment failed")
        try require(table?.rows[1] == ["a\\|b", "`left|right`", "3"], "Escaped or inline-code pipes split a cell")
        let missing = NativeMarkdownTable.parse(["A | B", "--- | ---", "only |", "too | many | ignored"], at: 0)?.table
        try require(missing?.rows == [["only", ""], ["too", "many"]], "Ragged table rows were not normalized")
        try require(NativeMarkdownTable.parse(["a|b", "not|separator"], at: 0) == nil, "Plain pipes became a table")
        let fenced = NativeMarkdownBlock.parse("````text\n" + rows.joined(separator: "\n") + "\n```\n````\n" + rows.joined(separator: "\n"))
        try require(fenced.filter { $0.table != nil }.count == 1 && fenced.first?.code == true && fenced.first?.content.contains("```") == true, "Tables leaked out of fenced code")
        try require(NativeHistoryPull.shouldPrefetch(firstVisibleIndex: 8, movingOlder: true), "Near-top user scroll must prefetch")
        try require(!NativeHistoryPull.shouldPrefetch(firstVisibleIndex: 9, movingOlder: true), "Distant scroll must not prefetch")
        try require(!NativeHistoryPull.shouldPrefetch(firstVisibleIndex: 2, movingOlder: false), "Passive changes must not prefetch")
        try require(abs(NativeHistoryPull.damped(100) - 40) < 0.01, "History pull must damp 100pt to 40pt")
        try require(NativeHistoryPull.damped(0) == 0, "History pull idle distance must be zero")
        // Real UIKit geometry: prepend twenty unequal-height messages and verify
        // both exact contentOffset compensation and the original message's pixels.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let host = UIViewController(); window.rootViewController = host
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        host.view.addSubview(scroll); window.isHidden = false
        defer { window.isHidden = true }
        let controller = NativeHistoryScrollController()
        let keys = (0..<50).map { "anchor-\($0)" }
        controller.configure(identity: "synthetic-anchor", enabled: false, keys: keys, onLoad: {}, onDragging: { _ in })
        let probe = UIView(frame: .zero); scroll.addSubview(probe); controller.attach(probe)
        let markers = keys.enumerated().map { index, key -> UIView in
            let row = UIView(frame: CGRect(x: 0, y: index * 80, width: 320, height: 80))
            scroll.addSubview(row); controller.register(key, view: row); return row
        }
        scroll.contentSize = CGSize(width: 320, height: 4000)
        // The response arrives after the reader has already moved further up.
        scroll.contentOffset.y = 1073
        controller.captureAnchor()
        let visible = markers[13]
        let originalY = visible.convert(visible.bounds, to: window).minY
        let insertedHeight = (0..<20).reduce(CGFloat(0)) { $0 + CGFloat(47 + $1 * 3) }
        for marker in markers { marker.frame.origin.y += insertedHeight }
        scroll.contentSize.height += insertedHeight
        controller.finish()
        try require(abs(scroll.contentOffset.y - (1073 + insertedHeight)) < 0.25, "Prepending history did not compensate the exact inserted height")
        try require(abs(visible.convert(visible.bounds, to: window).minY - originalY) < 0.25, "History prepend moved the visible message in screen pixels")
        // A second lazy-layout correction must preserve that same viewport too.
        for marker in markers { marker.frame.origin.y += 37 }
        scroll.contentSize.height += 37; controller.finish()
        try require(abs(visible.convert(visible.bounds, to: window).minY - originalY) < 0.25, "Late row measurement moved the history anchor")
        controller.releaseAnchor(); controller.detach()
        let context = NativeContextUsage(json(["usedTokens": .number(24000), "windowTokens": .number(128000)]))
        try require(context?.placeholder == "24K / 128K（18.8%）", "Context placeholder counts or percentage are wrong")
        let selectableMessage = SelectableMessageTextView()
        selectableMessage.text = "select only to copy"
        try require(!selectableMessage.isEditable, "Message text must not be editable")
        try require(selectableMessage.isSelectable, "Message text must support native selection")
        try require(selectableMessage.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil), "Message text must allow copying")
        try require(!selectableMessage.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil), "Message text must reject pasting")
        for (count, expected) in [(999, "999"), (1000, "1K"), (13679, "13.7K"), (999500, "1M"), (1250000, "1.25M")] {
            try require(NativeTokenCount.format(count) == expected, "Compact Token formatting failed for \(count)")
        }
        try require(NativeContextUsage(.null) == nil, "Missing context must not show a fabricated zero")
        try require(NativeContextUsage(json(["usedTokens": .number(1), "windowTokens": .number(0)])) == nil, "Zero context window must be unavailable")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("preview.swift")
        try Data("let value = 42\n".utf8).write(to: text)
        guard case .text(let content, let truncated)? = try NativePreviewContent.read(text) else { throw LinkError.message("Source file did not route to text preview") }
        try require(content == "let value = 42\n" && !truncated, "Text preview changed content")
        let utf16 = folder.appendingPathComponent("unicode.txt")
        try "中文预览".data(using: .utf16)!.write(to: utf16)
        guard case .text(let unicode, _)? = try NativePreviewContent.read(utf16), unicode == "中文预览" else { throw LinkError.message("UTF-16 preview failed") }
        let binary = folder.appendingPathComponent("package.zip")
        try Data("Synthetic zip contents".utf8).write(to: binary)
        try require(try NativePreviewContent.read(binary) == nil, "Archive was mistaken for text")
        let image = folder.appendingPathComponent("image.png")
        let data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        try data.write(to: image)
        guard case .image? = try NativePreviewContent.read(image) else { throw LinkError.message("Image did not route to preview") }
    }
    func run() async {
        guard result == "Testing…" else { return }
        let env = ProcessInfo.processInfo.environment
        var checks: [String] = []
        do {
            guard let port = env["LINK_SMOKE_PORT"].flatMap(Int.init), let pin = env["LINK_SMOKE_PIN"], let serverId = env["LINK_SMOKE_ID"],
                  let v4 = endpoint("127.0.0.1", port: port), let v6 = endpoint("::1", port: port) else { throw LinkError.message("Missing fixture configuration") }
            var peer = Peer(serverId: serverId, name: "Synthetic Mac", pin: pin, ipv4: ["127.0.0.1"], ipv6: ["::1"], port: port, deviceId: UUID().uuidString.lowercased(), secret: try Vault.secret(), approved: false)
            try Vault.save(peer); try require(try Vault.load()?.secret == peer.secret, "Keychain round trip failed"); checks.append("keychain")
            let link = PinnedAPI(base: v4, pin: pin); defer { link.close() }
            try await link.verify(serverId: serverId); checks.append("IPv4 pinned TLS")
            let wrong = PinnedAPI(base: v4, pin: String(repeating: "0", count: 64))
            var rejected = false; do { try await wrong.verify(serverId: serverId) } catch { rejected = true }; wrong.close()
            try require(rejected, "Wrong certificate accepted"); checks.append("wrong certificate rejected")
            let (_, pairCode) = try await link.call("link/pair", peer: peer); try require(pairCode == 202, "Pairing failed")
            try await Task.sleep(nanoseconds: 200_000_000)
            let (reply, code) = try await link.call("link/session", peer: peer)
            guard code == 200, let cookie = reply.cookie else { throw LinkError.message("Missing device session") }
            peer.approved = true; try Vault.save(peer)
            try await api.connect(base: v4, pin: pin, cookie: cookie)
            for _ in 0..<8 {
                await workspace.load()
                if workspace.sessions.count >= 2 { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try require(workspace.sessions.count >= 2, "Native session decoding failed: " + workspace.error)
            try require(!workspace.projects.isEmpty, "Native project index missing")
            try verifyToolRendering()
            try verifyMessageContent()
            checks.append("silent prefetch direction/8-row boundary + damped pull + 20-row pixel anchor/late layout + GFM tables/escaped pipes/code fences + image/text/UTF-16/archive preview routing")
            checks.append("structured multi-file diff parsing + line counts + Unicode command/output split + syntax highlighting")
            // XCTest uses the same live fixture after the full smoke pass.
            // Bootstrap its UI without rerunning mutations or fixed send-count assertions.
            if env["LINK_SMOKE_UI"] == "1" {
                UserDefaults.standard.removeObject(forKey: "native.commandLineWrapping")
                result = "UI ready"; return
            }
            checks.append("IPv4 native bootstrap + projects + session list")
            let readOnly = workspace.sessions.first { $0.readOnly == true }!
            let page: TimelinePage = try await api.request("/api/native/v1/threads/\(readOnly.id)/timeline")
            try require(page.capabilities["readOnly"].bool && !page.rows.isEmpty, "Read-only native timeline failed")
            rejected = false
            do { _ = try await api.value("/api/sessions/\(readOnly.id)/send", body: json(["text": string("DO NOT EXECUTE"), "id": string(UUID().uuidString.lowercased())])) } catch { rejected = true }
            try require(rejected, "Read-only history accepted a write")
            checks.append("typed history + server read-only guard")
            let settings = try await api.value("/api/codex-settings")
            let saved = try await api.value("/api/codex-settings", body: json(["revision": settings["revision"], "changes": json(["model_reasoning_effort": string("high")])]))
            try require(["saved", "unchanged"].contains(saved["status"].string), "Native synthetic config save failed")
            checks.append("native settings save + readback + CSRF")
            if let desktop = workspace.sessions.first(where: { $0.readOnly != true }) {
                let draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: draftDirectory) }
                let store = DraftStore(directory: draftDirectory)
                let testing = ChatModel(api: api, draftStore: store, draftScope: "synthetic-pairing")
                let task = Task { await testing.run(desktop) }
                for _ in 0..<40 { if !testing.rows.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                try require(testing.connected, "Desktop projection missing")
                for reference in ["/tmp/新版 IPA.ipa", "/tmp/file.swift:12", "/tmp/a%20b.txt", "/tmp/a(b)#c&d.txt", "file:///tmp/test.txt"] {
                    let rendered = NativeMessageLinks.attributed("[文件](<" + reference + ">)")
                    let file = json(["reference": string(reference), "id": string("synthetic-file")])
                    let link = rendered.runs.compactMap(\.link).first
                    try require(link != nil && NativeMessageLinks.file(for: link!, files: [file]) == file, "Local Markdown reference lost its link: " + reference)
                    try require(rendered.runs.contains { $0.link != nil && $0.foregroundColor == .blue && $0.underlineStyle == .single }, "File link is not highlighted")
                    try require(NativeMessageLinks.file(for: link!, files: []) == nil, "Unknown file bypassed the session artifact list")
                }
                let plain = NativeMessageLinks.attributed("[新版IPA](/tmp/新版 IPA.ipa)")
                try require(plain.runs.contains { $0.link != nil }, "Unwrapped local path lost its link")
                let external = NativeMessageLinks.attributed("[网站](https://example.com)")
                try require(external.runs.contains { $0.link?.absoluteString == "https://example.com" }, "External link changed")
                let code = "`[文件](/tmp/code.txt)`"
                try require(String(NativeMessageLinks.attributed(code).characters) == "[文件](/tmp/code.txt)", "Inline code destination was rewritten")
                guard let artifact = testing.files.first(where: { $0["name"].string.hasSuffix(".ipa") }), let artifactURL = NativeMessageLinks.url(reference: artifact["reference"].string) else { throw LinkError.message("Synthetic artifact missing") }
                try require(NativeMessageLinks.file(for: artifactURL, files: testing.files) == artifact, "Real timeline reference did not resolve")
                let downloaded = try await api.download("/api/sessions/\(desktop.id)/files/\(artifact["id"].string)", query: ["host": desktop.host], name: artifact["name"].string)
                defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                try require(try Data(contentsOf: downloaded) == Data("Synthetic IPA download fixture\n".utf8), "Artifact download bytes differ")
                checks.append("highlighted Unicode/space/encoded/line references + inline code + external links + authorized artifact download")
                let catalog = try await api.value("/api/sessions/\(desktop.id)/catalog")
                let primaryEfforts = NativeModelEfforts(catalog: catalog, model: "gpt-5.4")
                let restrictedEfforts = NativeModelEfforts(catalog: catalog, model: "synthetic-restricted")
                try require(primaryEfforts.values == ["low", "medium", "high"] && primaryEfforts.selection("low") == "low", "Supported reasoning effort was lost")
                try require(restrictedEfforts.values == ["minimal", "high"] && restrictedEfforts.selection("low") == "high", "Model switch ignored supported efforts or default")
                try require(restrictedEfforts.selection("high") == "high" && NativeModelEfforts(catalog: .null, model: "custom").values.contains("xhigh"), "Reasoning effort fallback failed")
                checks.append("model reasoning options + preserve compatible selection + model default + unavailable catalog fallback")
                guard let fileChange = testing.rows.first(where: { $0.kind == "fileChange" }) else { throw LinkError.message("File change fixture missing") }
                async let firstStats: Void = testing.loadFileChangeStats(fileChange)
                async let secondStats: Void = testing.loadFileChangeStats(fileChange)
                _ = await (firstStats, secondStats)
                try require(testing.fileChangeStats(fileChange)?.added == 2 && testing.fileChangeStats(fileChange)?.removed == 2, "Full tool diff stats missing or incorrect")
                try require(!testing.rowHasMore(fileChange), "Tool stats used a partial patch")
                checks.append("full paginated file-change stats + shared detail loading")
                let browser = NativeWorkspaceBrowserModel(api: api, session: desktop)
                await browser.loadRepositories()
                try require(browser.repositories.map(\.path) == ["", "apps/client", "apps/tools/worker"], "Nested repository discovery failed")
                await browser.loadChanges(source: "unstaged", repository: "apps/tools/worker")
                try require(browser.changes?.files.first?.path == "apps/tools/worker/tracked.txt", "Selected repository change paths lost workspace scope")
                await browser.open("apps/tools/worker/tracked.txt", diffSource: "unstaged", repository: "apps/tools/worker")
                try require(browser.document?.text.contains("+working nested") == true, "Selected repository patch mixed repositories")
                browser.document = nil
                checks.append("nested Git discovery + selected-repository changes + patch")
                await browser.loadFiles(directory: "", query: "")
                try require(browser.error.isEmpty && browser.entries.contains { $0.path == "Sources" }, "Workspace root listing failed")
                await browser.loadFiles(directory: "Sources", query: "")
                try require(browser.entries.contains { $0.path == "Sources/example.swift" }, "Workspace child navigation failed")
                await browser.loadFiles(directory: "", query: "EXAMPLE.SWIFT")
                try require(browser.entries.count == 1, "Workspace filename search failed")
                await browser.open("Sources/example.swift")
                try require(browser.document?.text.contains("working") == true, "Workspace preview did not use current file")
                try require(browser.document?.editable == true && browser.document?.revision != nil, "Full workspace text is not editable")
                let filePath = "/api/native/v1/threads/\(desktop.id)/workspace/file"
                let original: WorkspaceFilePreview = try await api.request(filePath, query: ["path": "README.txt"])
                let edited: WorkspaceFilePreview = try await api.request(filePath, body: json(["path": string("README.txt"), "revision": string(original.revision!), "text": string("Edited from native smoke\n")]))
                let reread: WorkspaceFilePreview = try await api.request(filePath, query: ["path": "README.txt"])
                try require(reread.text == edited.text && reread.revision == edited.revision, "Saved file did not persist on gateway")
                var conflict = false
                do { _ = try await api.value(filePath, body: json(["path": string("README.txt"), "revision": string(original.revision!), "text": string("stale overwrite")])) } catch { conflict = true }
                try require(conflict, "File save overwrote an externally changed revision")
                _ = try await api.value(filePath, body: json(["path": string("README.txt"), "revision": string(edited.revision!), "text": string(original.text)]))
                checks.append("workspace edit + save/readback + stale-revision conflict + original restored")
                for hint in ["file.swift", "file.rs", "script.py", "script.sh", "file.js", "file.ts", "file.tsx", "file.json", "file.yaml", "file.toml", "file.css", "file.html", "file.c", "file.md"] {
                    guard let grammar = NativeCodeLanguages.language(hint) else { throw LinkError.message("Missing grammar: " + hint) }
                    try require(grammar.highlightsQuery != nil, "Missing highlights: " + hint)
                    grammar.prepare()
                }
                let terminal = NativeTerminalText.attributed("\u{1b}[31merror\u{1b}[0m ok \u{1b}]8;;https://example.invalid\u{7}link\u{1b}]8;;\u{7}")
                try require(String(terminal.characters) == "error ok link" && terminal.runs.contains { $0.foregroundColor == .red } && terminal.runs.allSatisfy { $0.link == nil }, "Terminal output style or control stripping failed")
                checks.append("14 Runestone grammar highlight queries + ANSI color/reset + OSC controls removed")
                await browser.loadChanges(source: "unstaged")
                try require(browser.changes?.files.contains { $0.path == "README.txt" && $0.untracked } == true, "Untracked file missing")
                await browser.open("Sources/example.swift", diffSource: "unstaged")
                try require(browser.document?.text.contains("+let workspaceValue = \"working\"") == true, "Working-tree diff missing")
                await browser.loadChanges(source: "staged")
                await browser.open("Sources/example.swift", diffSource: "staged")
                try require(browser.document?.text.contains("+let workspaceValue = \"staged\"") == true, "Staged diff mixed with working-tree state")
                testing.draft.text = "Existing draft"
                try require(testing.appendWorkspaceContext("Sources/example.swift", for: desktop), "Workspace path not appended")
                try require(testing.draft.text == "Existing draft\n\nSources/example.swift", "Workspace insertion replaced the existing draft")
                try require(!testing.appendWorkspaceContext("wrong thread", for: readOnly), "Workspace insertion crossed session identity")
                checks.append("workspace browse + search + preview + staged/unstaged diffs + append-only draft context")
                testing.draft.text = "Unsent across process restart"
                testing.flushDraft()
                let reopenedStore = DraftStore(directory: draftDirectory)
                try require(try reopenedStore.load(scope: "synthetic-pairing", identity: desktop.identity)?.text == "Unsent across process restart", "Durable draft did not survive store recreation")
                try require(try reopenedStore.load(scope: "other-pairing", identity: desktop.identity) == nil, "Draft leaked across pairing identities")
                try require(try reopenedStore.load(scope: "synthetic-pairing", identity: "other-host|" + desktop.id) == nil, "Draft leaked across hosts")
                var attachmentDraft = ChatDraft(); attachmentDraft.text = "Attachment draft"
                attachmentDraft.attachments = [PendingAttachment(id: "ephemeral-upload", name: "test.txt", size: 12)]
                try store.save(attachmentDraft, scope: "synthetic-pairing", identity: "attachment-test")
                let recoveredAttachment = try reopenedStore.load(scope: "synthetic-pairing", identity: "attachment-test")
                try require(recoveredAttachment?.attachments.isEmpty == true && recoveredAttachment?.recoveryNotice.contains("test.txt") == true, "Stale upload ID restored or attachment warning missing")
                let corruptDirectory = draftDirectory.appendingPathComponent("corrupt-case")
                let corruptStore = DraftStore(directory: corruptDirectory)
                try corruptStore.save(attachmentDraft, scope: "corrupt-pairing", identity: desktop.identity)
                let scopeFolder = try FileManager.default.contentsOfDirectory(at: corruptDirectory, includingPropertiesForKeys: nil)[0]
                let corruptFile = try FileManager.default.contentsOfDirectory(at: scopeFolder, includingPropertiesForKeys: nil)[0]
                let corruptBytes = Data("not a draft JSON".utf8)
                try corruptBytes.write(to: corruptFile)
                let corruptModel = ChatModel(api: api, draftStore: corruptStore, draftScope: "corrupt-pairing")
                let corruptTask = Task { await corruptModel.run(desktop) }
                for _ in 0..<40 { if corruptModel.connected { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                try await Task.sleep(nanoseconds: 400_000_000)
                corruptModel.flushDraft()
                try require(!corruptModel.draftStorageError.isEmpty && Data(contentsOf: corruptFile) == corruptBytes, "Restore failure overwrote the unreadable draft")
                corruptTask.cancel()
                corruptModel.setDraftScope("replacement-pairing")
                try require(corruptModel.draftStorageError.isEmpty, "Restore error leaked into replacement pairing")
                corruptModel.primeDraft("New pairing draft", for: desktop)
                try require(try corruptStore.load(scope: "replacement-pairing", identity: desktop.identity)?.text == "New pairing draft", "Unreadable state blocked a replacement pairing")
                try require(Data(contentsOf: corruptFile) == corruptBytes, "Replacement pairing overwrote the original unreadable draft")
                corruptModel.clear()
                checks.append("unreadable draft retained + replacement pairing recovers independently")
                checks.append("durable drafts + pairing/host isolation + attachment reselection")
                testing.draft.text = "Synthetic send test"
                await testing.send(); try require(testing.draft.text.isEmpty, "Native send did not acknowledge")
                let before = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(before["sendCount"].int == 1, "Send duplicated")
                testing.draft.text = "Synthetic retry"
                await testing.send(); try require(testing.draft.text == "Synthetic retry", "Unconfirmed send lost draft")
                let retryID = testing.draft.attempt?.id
                task.cancel(); testing.clear()
                let resumed = ChatModel(api: api, draftStore: reopenedStore, draftScope: "synthetic-pairing")
                let resumedTask = Task { await resumed.run(desktop) }
                defer { resumedTask.cancel() }
                for _ in 0..<40 { if resumed.connected { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                try require(resumed.draft.text == "Synthetic retry" && resumed.draft.attempt?.id == retryID, "Relaunch lost pending request ID")
                let noReplay = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(noReplay["lastAttemptCount"].int == 1, "Restoring a draft automatically replayed a send")
                await resumed.send(); try require(resumed.draft.text.isEmpty, "Retry not acknowledged")
                try require(try reopenedStore.load(scope: "synthetic-pairing", identity: desktop.identity) == nil, "Confirmed send left a recoverable draft")
                let after = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(after["sendCount"].int == 2 && after["lastAttemptCount"].int == 2, "Retry changed idempotency key")
                resumed.draft.sendMode = "send"
                resumed.draft.text = "Synthetic one-off queued message"
                await resumed.send(mode: "queue")
                let overrideMode = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(overrideMode["lastSendMode"].string == "queue" && resumed.draft.sendMode == "send", "One-off send changed the default or ignored the chosen mode")
                resumed.draft.text = "Synthetic default send after override"
                await resumed.send()
                let defaultMode = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(defaultMode["lastSendMode"].string == "send", "Single tap did not restore default send mode")
                try await resumed.stop()
                if let request = resumed.requests.first { try await resumed.respond(request, response: json(["decision": string("decline")])) }
                resumed.draft.text = "Forget while a save is pending"
                resumed.forgetDrafts()
                try await Task.sleep(nanoseconds: 400_000_000)
                try require(try reopenedStore.load(scope: "synthetic-pairing", identity: desktop.identity) == nil, "Delayed save recreated forgotten drafts")
                resumedTask.cancel()
                checks.append("relaunch without replay + stable retry ID + acknowledged cleanup + forget cancels save")
                checks.append("native send + uncertain retry ID + stop + approval response")
            }
            if let desktop = workspace.sessions.first(where: { $0.readOnly != true }) {
                try await workspace.preferences([desktop], changes: ["pinned": .bool(true), "unread": .bool(true)])
                let unread = workspace.sessions.first { $0.identity == desktop.identity }!
                try require(unread.unread == true && unread.pinned == true, "Session preferences did not persist")
                workspace.selected = unread
                for _ in 0..<30 {
                    if workspace.sessions.first(where: { $0.identity == desktop.identity })?.unread == false { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try require(workspace.sessions.first(where: { $0.identity == desktop.identity })?.unread == false, "Opening a session did not mark it read")
                workspace.selected = nil
                if let project = workspace.projects.first(where: { $0.registered == true }) {
                    try await workspace.preferences([desktop], changes: ["projectKey": string(project.key)])
                    try require(workspace.sessions.first(where: { $0.identity == desktop.identity })?.projectKey == project.key, "Project assignment did not persist")
                    try await workspace.preferences([desktop], changes: ["projectKey": .null])
                }
                let markdown = try await workspace.copyMarkdown(desktop)
                try require(markdown.contains("## 用户") && markdown.contains("## Codex") && markdown.contains("Synthetic output final page") && markdown.contains("new docs"), "Markdown export omitted full message/tool content")
                let historyMarkdown = try await workspace.copyMarkdown(readOnly)
                try require(historyMarkdown.contains("## 用户"), "Read-only Markdown export failed")
                checks.append("pin + unread + mark read on open + project assignment/reset + full Markdown export")
                try await workspace.fork(desktop)
                guard let child = workspace.selected, child.id != desktop.id else { throw LinkError.message("Fork did not open the new conversation") }
                workspace.selected = nil
                try await workspace.archive(child)
                var archivedChild = child; archivedChild.archived = true
                try await workspace.archive(archivedChild)
                try await workspace.permanentlyDelete(child)
                var missing = false
                do { let _: LinkSession = try await api.request("/api/session-meta/\(child.id)") } catch { missing = true }
                try require(missing, "Deleted synthetic branch remains discoverable")
                try require(workspace.sessions.contains(where: { $0.identity == desktop.identity }), "Deleting a branch removed its source")
                checks.append("fork latest completed turn + open child + archive/unarchive + confirmed precise deletion")
            }
            let remote = PinnedAPI(base: v6, pin: pin); defer { remote.close() }
            try await remote.verify(serverId: serverId)
            let (next, nextCode) = try await remote.call("link/session", peer: peer)
            guard nextCode == 200, let nextCookie = next.cookie else { throw LinkError.message("IPv6 authentication failed") }
            try await api.connect(base: v6, pin: pin, cookie: nextCookie); await workspace.load()
            try require(workspace.sessions.count >= 2, "IPv6 native list failed")
            checks.append("IPv6 pinned native API + automatic cookie/CSRF session")
            try Vault.forget(); try require(try Vault.load() == nil, "Keychain forget failed")
            // Leave synthetic UI available for screenshots and XCTest gestures.
            workspace.selected = nil
            result = "PASS"
        } catch { result = "FAIL: " + error.localizedDescription }
        let report: [String: Any] = ["result": result, "checks": checks]
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("smoke.json"))
    }
}
#endif
