import SwiftUI

#if !LINK_SMOKE
@main
struct CodexLinkApp: App {
    @StateObject private var connection = Connection()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(connection: connection, browser: connection.browser)
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
    @ObservedObject var browser: BrowserSession
    @State private var settings = false
    @State private var confirmForget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(connection.online ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(connection.status).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button { connection.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新连接")
                Button { settings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("连接设置")
            }
            .padding(12)
            Divider()
            if connection.connectedURL != nil {
                BrowserView(browser: browser)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 52)).foregroundStyle(.tint)
                    Text("codex-link").font(.largeTitle.bold())
                    Text("Mac 运行网关，iPhone 加入同一 Wi-Fi。\n自动发现后，在 Mac 点一次允许。\n无需扫码、无需密码。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if connection.peer == nil {
                        ForEach(connection.nearby) { mac in
                            Button("连接 " + mac.name) { connection.select(mac) }.buttonStyle(.borderedProminent)
                        }
                    }
                    Text("出门后尝试已保存的公网 IPv6。Mac 需保持在线，手机网络需支持 IPv6。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section("连接") {
                        Text(connection.status)
                        if let url = connection.connectedURL { Text(url.absoluteString).font(.caption).textSelection(.enabled) }
                        Button("重新探测地址") { connection.reconnect() }
                        Button("刷新聊天页面（未发送草稿可能丢失）") { browser.reload(); settings = false }
                    }
                    if let peer = connection.peer {
                        Section("已记住的 Mac") {
                            Text(peer.name)
                            Text("设备 ID：" + peer.deviceId).font(.caption).textSelection(.enabled)
                            Text("局域网：" + peer.ipv4.joined(separator: ", ")).font(.caption)
                            Text("IPv6：" + (peer.ipv6.isEmpty ? "尚未发现" : peer.ipv6.joined(separator: "\n"))).font(.caption).textSelection(.enabled)
                            Text("证书 SHA-256：" + peer.pin).font(.caption2).textSelection(.enabled)
                        }
                        Section {
                            Button("忘记此 Mac", role: .destructive) { confirmForget = true }
                        } footer: {
                            Text("只清除本机密钥。撤销旧授权请在 Mac 运行 --revoke。公网地址变化且无法直连时，需要回到局域网更新。")
                        }
                    }
                }
                .navigationTitle("连接设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
                .confirmationDialog("忘记后需要回到局域网重新配对", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("忘记", role: .destructive) { connection.forget(); settings = false }
                }
            }
        }
        .sheet(isPresented: Binding(get: { browser.downloadedFile != nil }, set: { if !$0 { browser.downloadedFile = nil } })) {
            if let file = browser.downloadedFile { ShareView(file: file) }
        }
    }
}
