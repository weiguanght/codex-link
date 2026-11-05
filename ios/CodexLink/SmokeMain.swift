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
    @State private var initialPrompt = ""
    var body: some View {
        NavigationStack {
            NativeChatView(chat: smoke.chat, workspace: smoke.workspace, onSidebar: { sidebar = true }, onNewChat: { prompt in initialPrompt = prompt; create = true }, onSettings: { settings = true })
                .overlay(alignment: .top) { if smoke.result.hasPrefix("FAIL") { Text(smoke.result).font(.caption).foregroundStyle(.red).padding().background(.regularMaterial) } }
                .sheet(isPresented: $sidebar) { NavigationStack { NativeLibraryView(model: smoke.workspace, onSelect: { smoke.workspace.selected = $0; sidebar = false }, onNewChat: { sidebar = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { create = true } }, onSettings: { sidebar = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settings = true } }) } }
                .sheet(isPresented: $create) { NativeNewChat(model: smoke.workspace, initialPrompt: initialPrompt) { row in smoke.chat.primeDraft(initialPrompt, for: row); smoke.workspace.selected = row; initialPrompt = "" } }
                .sheet(isPresented: $settings) { NavigationStack { NativeCodexSettings(api: smoke.api, workspace: smoke.workspace, initialScope: "") } }
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
            // XCTest uses the same live fixture after the full smoke pass.
            // Bootstrap its UI without rerunning mutations or fixed send-count assertions.
            if env["LINK_SMOKE_UI"] == "1" { result = "UI ready"; return }
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
                guard let artifact = testing.files.first, let artifactURL = NativeMessageLinks.url(reference: artifact["reference"].string) else { throw LinkError.message("Synthetic artifact missing") }
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
                let browser = NativeWorkspaceBrowserModel(api: api, session: desktop)
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
