import Foundation
import CryptoKit
import Security

struct Peer: Codable {
    var serverId: String
    var name: String
    var pin: String
    var ipv4: [String]
    var ipv6: [String]
    var port: Int
    var deviceId: String
    var secret: String
    var approved: Bool

    var credentials: [String: String] {
        ["deviceId": deviceId, "secret": secret, "name": "iPhone · codex-link"]
    }
}

struct ServerInfo: Decodable {
    let serverId: String
    let name: String
    let port: Int
    let ipv4: [String]
    let ipv6: [String]
    let certificateSHA256: String
}

struct LinkCookie: Decodable {
    let name: String
    let value: String
    let maxAge: Int
}

struct LinkReply: Decodable {
    let state: String?
    let info: ServerInfo?
    let cookie: LinkCookie?
    let error: String?
}

enum LinkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum Vault {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.codex.link.pairing",
        kSecAttrAccount as String: "primary-mac"
    ]

    static func load() throws -> Peer? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else {
            throw LinkError.message("无法读取钥匙串（\(code)），请解锁后重试")
        }
        return try JSONDecoder().decode(Peer.self, from: data)
    }

    static func save(_ peer: Peer) throws {
        let data = try JSONEncoder().encode(peer)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var code = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            code = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw LinkError.message("无法保存设备密钥（\(code)）") }
    }

    static func forget() throws {
        let code = SecItemDelete(base as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else {
            throw LinkError.message("无法清除设备密钥（\(code)）")
        }
    }

    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LinkError.message("无法生成设备密钥")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

func bareHost(_ host: String) -> String {
    host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
}

func endpoint(_ address: String, port: Int) -> URL? {
    guard (1...65535).contains(port) else { return nil }
    let host = address.contains(":") ? "[\(address)]" : address
    return URL(string: "https://\(host):\(port)")
}

func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme == "https" && b.scheme == "https" &&
    bareHost(a.host ?? "") == bareHost(b.host ?? "") && (a.port ?? 443) == (b.port ?? 443)
}

func pinnedCredential(_ challenge: URLAuthenticationChallenge, endpoint: URL, pin: String) -> URLCredential? {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          bareHost(challenge.protectionSpace.host) == bareHost(endpoint.host ?? ""),
          challenge.protectionSpace.port == (endpoint.port ?? 443),
          let trust = challenge.protectionSpace.serverTrust,
          let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let certificate = certificates.first else { return nil }
    let bytes = SecCertificateCopyData(certificate) as Data
    let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    // Exact certificate identity pinned at local pairing; never global trust bypass.
    guard actual == pin else { return nil }
    return URLCredential(trust: trust)
}

final class PinnedAPI: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let base: URL
    let pin: String
    private var session: URLSession!

    init(base: URL, pin: String) {
        self.base = base
        self.pin = pin
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = pinnedCredential(challenge, endpoint: base, pin: pin) {
            completionHandler(.useCredential, credential)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a device secret across a redirect.
    }

    func request(_ path: String, credentials: [String: String]? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("1", forHTTPHeaderField: "X-Codex-Link")
        if let credentials {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: credentials)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 16384 else {
            throw LinkError.message("网关响应无效")
        }
        return (data, response.statusCode)
    }

    func verify(serverId: String) async throws {
        let (data, code) = try await request("link/identity")
        guard code == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["serverId"] as? String == serverId, object["protocol"] as? Int == 1 else {
            throw LinkError.message("Mac 身份或协议不匹配")
        }
    }

    func call(_ path: String, peer: Peer) async throws -> (LinkReply, Int) {
        let (data, code) = try await request(path, credentials: peer.credentials)
        return (try JSONDecoder().decode(LinkReply.self, from: data), code)
    }
}
