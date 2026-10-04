// Compiled ONLY by scripts/test-ios-smoke.sh. No test entry point in release IPA.
#if LINK_SMOKE
import SwiftUI
import WebKit

@main
struct SmokeMain: App {
    @StateObject private var smoke = Smoke()
    var body: some Scene {
        WindowGroup {
            VStack { Text(smoke.result); BrowserView(browser: smoke.browser) }
                .task { await smoke.run() }
        }
    }
}

@MainActor
final class Smoke: ObservableObject {
    @Published var result = "Testing…"
    let browser = BrowserSession()

    func require(_ value: Bool, _ message: String) throws {
        if !value { throw LinkError.message(message) }
    }

    func run() async {
        let env = ProcessInfo.processInfo.environment
        var checks: [String] = []
        do {
            guard let portString = env["LINK_SMOKE_PORT"], let port = Int(portString),
                  let pin = env["LINK_SMOKE_PIN"], let serverId = env["LINK_SMOKE_ID"],
                  let v4 = endpoint("127.0.0.1", port: port), let v6 = endpoint("::1", port: port) else {
                throw LinkError.message("Missing synthetic fixture configuration")
            }
            var peer = Peer(serverId: serverId, name: "Synthetic Mac", pin: pin,
                            ipv4: ["127.0.0.1"], ipv6: ["::1"], port: port,
                            deviceId: UUID().uuidString.lowercased(), secret: try Vault.secret(), approved: false)
            try Vault.save(peer)
            try require(try Vault.load()?.secret == peer.secret, "Keychain round trip failed")
            checks.append("keychain")
            let api = PinnedAPI(base: v4, pin: pin)
            defer { api.close() }
            try await api.verify(serverId: serverId)
            checks.append("IPv4 pinned TLS")
            let wrong = PinnedAPI(base: v4, pin: String(repeating: "0", count: 64))
            var rejected = false
            do { try await wrong.verify(serverId: serverId) } catch { rejected = true }
            wrong.close()
            try require(rejected, "Wrong certificate accepted")
            checks.append("wrong certificate rejected")
            let (_, pairCode) = try await api.call("link/pair", peer: peer)
            try require(pairCode == 202, "Pair request failed")
            try await Task.sleep(nanoseconds: 200_000_000)
            let (session, code) = try await api.call("link/session", peer: peer)
            try require(code == 200, "Session request failed")
            guard let cookie = session.cookie else { throw LinkError.message("Missing cookie") }
            peer.approved = true
            try Vault.save(peer)
            try await browser.connect(base: v4, fingerprint: pin, cookie: cookie)
            try await checkWeb()
            checks.append("IPv4 WKWebView cookie + authenticated upstream HTML")
            let remote = PinnedAPI(base: v6, pin: pin)
            defer { remote.close() }
            try await remote.verify(serverId: serverId)
            let (next, nextCode) = try await remote.call("link/session", peer: peer)
            try require(nextCode == 200, "IPv6 device authentication failed")
            guard let nextCookie = next.cookie else { throw LinkError.message("Missing IPv6 cookie") }
            try await browser.connect(base: v6, fingerprint: pin, cookie: nextCookie)
            try await checkWeb()
            checks.append("IPv6 WKWebView cookie + authenticated upstream HTML")
            try Vault.forget()
            try require(try Vault.load() == nil, "Keychain forget failed")
            result = "PASS"
        } catch { result = "FAIL: " + error.localizedDescription }
        let report: [String: Any] = ["result": result, "checks": checks]
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path)
    }

    func checkWeb() async throws {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if browser.webView.isLoading { continue }
            do {
                let value: Any = try await withCheckedThrowingContinuation { continuation in
                    browser.webView.callAsyncJavaScript(
                        "const r = await fetch('/api/auth'); return await r.json();", arguments: [:], in: nil, in: .page,
                        completionHandler: { outcome in continuation.resume(with: outcome) })
                }
                if let auth = value as? [String: Any], auth["authenticated"] as? Bool == true { return }
            } catch { continue }
        }
        throw LinkError.message("WKWebView did not load an authenticated HTTPS page")
    }
}
#endif
