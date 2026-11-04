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
                let testing = ChatModel(api: api)
                let task = Task { await testing.run(desktop) }
                for _ in 0..<40 { if !testing.rows.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                try require(testing.connected, "Desktop projection missing")
                testing.draft.text = "Synthetic send test"
                await testing.send(); try require(testing.draft.text.isEmpty, "Native send did not acknowledge")
                let before = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(before["sendCount"].int == 1, "Send duplicated")
                testing.draft.text = "Synthetic retry"
                await testing.send(); try require(testing.draft.text == "Synthetic retry", "Unconfirmed send lost draft")
                await testing.send(); try require(testing.draft.text.isEmpty, "Retry not acknowledged")
                let after = try await api.value("/api/sessions/\(desktop.id)/catalog")
                try require(after["sendCount"].int == 2 && after["lastAttemptCount"].int == 2, "Retry changed idempotency key")
                try await testing.stop()
                if let request = testing.requests.first { try await testing.respond(request, response: json(["decision": string("decline")])) }
                task.cancel(); testing.clear()
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
