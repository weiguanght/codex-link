import SwiftUI

#if !LINK_SMOKE
@main
struct CodexLinkApp: App {
    @StateObject private var connection = Connection()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(connection: connection)
                .onAppear { connection.activate() }
                .onChange(of: phase) { phase in
                    if phase == .active { connection.activate() }
                    else if phase == .background { connection.deactivate() }
                }
        }
    }
}
#endif

struct ContentView: View {
    @ObservedObject var connection: Connection
    @ObservedObject var api: NativeAPI
    @StateObject private var workspace: WorkspaceModel
    @StateObject private var chat: ChatModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var sidebar = false
    @State private var settings = false
    @State private var newChat = false
    @State private var initialPrompt = ""
    @AppStorage("native.appearance") private var appearance = "system"

    init(connection: Connection) {
        self.connection = connection; api = connection.api
        _workspace = StateObject(wrappedValue: WorkspaceModel(api: connection.api))
        _chat = StateObject(wrappedValue: ChatModel(api: connection.api))
    }
    var body: some View {
        layout
            .tint(.primary)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .task(id: workspace.filterID) {
                do { try await Task.sleep(nanoseconds: 250_000_000); if !Task.isCancelled { await workspace.load() } } catch {}
            }
            .task(id: chatTaskID) { if phase == .active { await chat.run(workspace.selected) } }
            .onChange(of: connection.peer?.deviceId) { value in if value == nil { workspace.clear(); chat.clear() } }
            .sheet(isPresented: $sidebar) { librarySheet.presentationDragIndicator(.visible) }
            .sheet(isPresented: $newChat) { NativeNewChat(model: workspace, initialPrompt: initialPrompt) { row in chat.primeDraft(initialPrompt, for: row); select(row); initialPrompt = "" } }
            .sheet(isPresented: $settings) { NavigationStack { NativeAppSettings(connection: connection, workspace: workspace) } }
    }
    private var chatTaskID: String {
        let identity = workspace.selected?.identity ?? "none"
        return [identity, String(api.generation), String(chat.logView), phaseKey].joined(separator: "|")
    }
    private var layout: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular && connection.connectedURL != nil {
                librarySheet.frame(width: 320)
                Divider()
            }
            NavigationStack {
                if connection.connectedURL != nil {
                    NativeChatView(chat: chat, workspace: workspace, onSidebar: { sidebar = true }, onNewChat: { prompt in initialPrompt = prompt; newChat = true }, onSettings: { settings = true }, showSidebar: sizeClass != .regular)
                } else { NativeWelcome(connection: connection, onSettings: { settings = true }) }
            }
        }
    }
    private var librarySheet: some View {
        NavigationStack {
            NativeLibraryView(model: workspace, onSelect: select, onNewChat: {
                sidebar = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { newChat = true }
            }, onSettings: {
                sidebar = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settings = true }
            })
        }
    }
    private var phaseKey: String { phase == .active ? "active" : "inactive" }
    private func select(_ row: LinkSession) { chat.logView = false; workspace.selected = row; sidebar = false }
}

struct NativeWelcome: View {
    @ObservedObject var connection: Connection
    let onSettings: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Image(systemName: "terminal").font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.linkCanvas).frame(width: 66, height: 66)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 21))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Codex Link").font(.largeTitle.weight(.semibold))
                    Text("离开电脑，也能接着做。").font(.title3).foregroundStyle(.secondary)
                }
                NativeNotice(text: connection.status)
                VStack(alignment: .leading, spacing: 24) {
                    step("wifi", "同一个 Wi-Fi，自动发现", "在 Mac 启动网关，iPhone 会在这里找到它。")
                    step("checkmark.shield", "只需确认一次", "首次在 Mac 点允许，无需密码或扫码。")
                    step("network", "出门继续连接", "自动使用已记住的公网 IPv6。")
                }
                if connection.peer == nil {
                    ForEach(connection.nearby) { mac in
                        Button { connection.select(mac) } label: { Label("连接 " + mac.name, systemImage: "laptopcomputer").frame(maxWidth: .infinity).padding(10) }.buttonStyle(.borderedProminent).tint(.primary)
                    }
                }
            }.padding(28).padding(.top, 30).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { NativeIconButton(symbol: "slider.horizontal.3", label: "连接设置", action: onSettings) } }
    }
    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).frame(width: 24).font(.title3)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
