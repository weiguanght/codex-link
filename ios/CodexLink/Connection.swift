import Foundation
import SwiftUI
import Network

@MainActor
final class Connection: ObservableObject {
    @Published var status = "正在寻找同一局域网的 Mac…"
    @Published var nearby: [DiscoveredMac] = []
    @Published var peer: Peer?
    @Published var connectedURL: URL?
    @Published var online = false
    let browser = BrowserSession()
    private let discovery = Discovery()
    private let monitor = NWPathMonitor()
    private var wifi = true
    private var active = false
    private var busy = false
    private var fatalVaultError = false
    private var heartbeat: Task<Void, Never>?
    private var autoPair: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var issuedAt = Date.distantPast
    private var epoch = 0

    init() {
        do { peer = try Vault.load() }
        catch { fatalVaultError = true; status = error.localizedDescription }
        discovery.onChange = { [weak self] result in
            guard let self else { return }
            self.nearby = result
            if self.peer != nil { self.reconnect() }
            else {
                self.autoPair?.cancel()
                self.autoPair = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let self, self.active, !self.fatalVaultError else { return }
                    if self.nearby.count == 1 { self.select(self.nearby[0]) }
                    else if self.nearby.count > 1 { self.status = "发现多台 Mac，请选择要连接的一台" }
                }
            }
        }
        discovery.onError = { [weak self] message in self?.status = message }
        browser.onFailure = { [weak self] message in
            self?.status = "页面连接异常：" + message
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let owner = self
            Task { @MainActor in
                guard let self = owner else { return }
                self.wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                if self.active { self.discovery.start(); self.reconnect() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "CodexLink.network"))
    }

    func activate() {
        guard !active else { return }
        active = true
        discovery.start()
        reconnect()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.discovery.refreshAddresses()
                self?.reconnect()
            }
        }
    }

    func deactivate() {
        active = false
        heartbeat?.cancel()
        autoPair?.cancel()
        operation?.cancel()
        discovery.stop()
    }

    func select(_ mac: DiscoveredMac) {
        guard peer == nil, !fatalVaultError else { return }
        do {
            let saved = Peer(serverId: mac.id, name: mac.name, pin: mac.pin, ipv4: mac.addresses,
                             ipv6: [], port: mac.port, deviceId: UUID().uuidString.lowercased(),
                             secret: try Vault.secret(), approved: false)
            // Save pending credentials before asking permission: an interrupted
            // approval can be recovered without asking the Mac a second time.
            try Vault.save(saved)
            peer = saved
            reconnect()
        } catch { status = error.localizedDescription }
    }

    func reconnect() {
        guard active, !busy, peer != nil, !fatalVaultError else { return }
        busy = true
        let generation = epoch
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            await self.connect(generation: generation)
        }
    }

    private func connect(generation: Int) async {
        guard var saved = peer else { return }
        let matches = nearby.filter { $0.id == saved.serverId && $0.pin == saved.pin }
        if nearby.contains(where: { $0.id == saved.serverId && $0.pin != saved.pin }) {
            status = "发现身份冲突：不会信任或替换已有 Mac 证书"
            // Old pinned endpoints remain usable; discovery cannot overwrite them.
        }
        var candidates: [URL] = []
        if wifi {
            for mac in matches { candidates += mac.addresses.compactMap { endpoint($0, port: mac.port) } }
            candidates += saved.ipv4.compactMap { endpoint($0, port: saved.port) }
        }
        if saved.approved { candidates += saved.ipv6.compactMap { endpoint($0, port: saved.port) } }
        var seen = Set<URL>()
        candidates = candidates.filter { seen.insert($0).inserted }
        var lastError = "尚未找到可连接地址；请先在同一 Wi-Fi 配对"
        for base in candidates {
            guard !Task.isCancelled, active, generation == epoch else { return }
            let api = PinnedAPI(base: base, pin: saved.pin)
            defer { api.close() }
            do {
                try await api.verify(serverId: saved.serverId)
                if !saved.approved {
                    let (pair, code) = try await api.call("link/pair", peer: saved)
                    guard code == 200 || code == 202 else {
                        throw LinkError.message(pair.error ?? "首次配对仅限 IPv4 局域网")
                    }
                    guard pair.state == "pending" || pair.state == "approved" else {
                        throw LinkError.message("配对被拒绝或已过期，请在设置中忘记此 Mac 后重试")
                    }
                    status = "已发现 \(saved.name)，请在 Mac 上点一次“允许”"
                    // Poll only authentication, never replay a Codex action.
                    for _ in 0..<45 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        guard active, generation == epoch else { return }
                        let (reply, code) = try await api.call("link/session", peer: saved)
                        if code == 202 { continue }
                        guard code == 200 else {
                            throw LinkError.message("配对未获允许；可在设置中忘记此 Mac 后重试")
                        }
                        try await accept(reply, saved: &saved, base: base, generation: generation)
                        return
                    }
                    throw LinkError.message("等待 Mac 确认超时")
                }
                let reuse = connectedURL == base && !browser.needsReload && Date().timeIntervalSince(issuedAt) < 6 * 3600
                let (reply, code) = try await api.call(reuse ? "link/status" : "link/session", peer: saved)
                guard code == 200 else {
                    if reply.state == "revoked" || reply.state == "denied" || reply.state == "unknown" {
                        status = "这台 iPhone 的授权已撤销或丢失，请在局域网重新配对"
                        online = false
                        browser.clear()
                        connectedURL = nil
                        return
                    }
                    throw LinkError.message(reply.error ?? "设备认证失败")
                }
                try await accept(reply, saved: &saved, base: base, generation: generation)
                return
            } catch {
                if Task.isCancelled || generation != epoch { return }
                lastError = error.localizedDescription
            }
        }
        guard generation == epoch else { return }
        online = false
        status = "未连接：\(lastError)。将自动重试；IPv6 变化后需回到局域网更新。"
    }

    private func accept(_ reply: LinkReply, saved: inout Peer, base: URL, generation: Int) async throws {
        guard !Task.isCancelled, active, generation == epoch,
              let info = reply.info, info.serverId == saved.serverId,
              info.certificateSHA256 == saved.pin, (1...65535).contains(info.port) else {
            throw LinkError.message("网关身份不匹配或连接已取消")
        }
        saved.approved = true
        saved.name = info.name
        saved.port = info.port
        saved.ipv4 = Array(info.ipv4.prefix(8))
        // Prefer current stable IPv6; retain a bounded fallback if IPv6 vanishes briefly.
        var seen = Set<String>()
        saved.ipv6 = Array((info.ipv6 + saved.ipv6).filter { seen.insert($0).inserted }.prefix(8))
        try Vault.save(saved)
        peer = saved
        if let cookie = reply.cookie {
            try await browser.connect(base: base, fingerprint: saved.pin, cookie: cookie)
            issuedAt = Date()
        }
        guard !Task.isCancelled, active, generation == epoch else { return }
        connectedURL = base
        online = true
        status = (bareHost(base.host ?? "").contains(":") ? "IPv6 直连 · " : "局域网 IPv4 · ") + saved.name
    }

    func forget() {
        do {
            try Vault.forget()
            epoch += 1
            operation?.cancel()
            peer = nil
            connectedURL = nil
            online = false
            fatalVaultError = false
            browser.clear()
            status = "已忘记 Mac；请在同一 Wi-Fi 重新发现。旧设备授权需在 Mac 端撤销。"
            if active { discovery.start() }
        } catch { status = error.localizedDescription }
    }
}
