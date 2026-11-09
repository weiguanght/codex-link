import Foundation

/// Flexible values only for the evolving Codex settings/request payloads.
/// Lists and cursor pages decode through typed models below.
enum JSONValue: Codable, Equatable, Hashable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var int: Int { if case .number(let v) = self { return Int(v) }; return 0 }
    var identifier: String { if case .number(let v) = self { return String(Int(v)) }; return string }
    var pretty: String {
        if case .string(let v) = self { return v }
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
func json(_ values: [String: JSONValue]) -> JSONValue { .object(values) }
func string(_ value: String) -> JSONValue { .string(value) }

struct LinkSession: Decodable, Identifiable, Hashable {
    let id: String
    var title: String
    let cwd: String?
    let host: String
    let hostLabel: String?
    let projectKey: String?
    let projectName: String?
    let readOnly: Bool?
    let originator: String?
    let historyReadable: Bool?
    var pinned: Bool?
    var hidden: Bool?
    var unread: Bool?
    var archived: Bool?
    let recency: Double?
    var identity: String { host + "|" + id }
}
struct LinkProject: Decodable, Identifiable, Hashable {
    let key: String
    var name: String
    let cwd: String
    let host: String
    let hostLabel: String?
    let count: Int?
    let registered: Bool?
    let hidden: Bool?
    var id: String { key }
}
struct SessionPage: Decodable {
    let sessions: [LinkSession]
    let projects: [LinkProject]
    let total: Int
    let hasMore: Bool
    let warnings: [String]?
}
struct NativeRow: Decodable, Identifiable, Equatable {
    let key: String
    let order: Int
    let role: String
    let kind: String?
    let title: String?
    let text: String
    let version: JSONValue
    let truncated: Bool?
    let editable: Bool?
    let forkable: Bool?
    let attachments: [JSONValue]?
    let status: String?
    let inputLength: Int?
    let exitCode: Int?
    let durationMs: Int?
    var id: String { key }
    var isProcess: Bool { role == "activity" }
}
struct TimelinePage: Decodable {
    let epoch: String
    let sequence: Int
    let rows: [NativeRow]
    let before: String?
    let hasMore: Bool?
    let reset: Bool?
    let meta: JSONValue
    let capabilities: JSONValue
    let files: [JSONValue]?
}

/// Cookies stay in memory. Every request is pinned and cannot follow redirects.
@MainActor
final class NativeAPI: ObservableObject {
    @Published private(set) var generation = 0
    private var transport: PinnedAPI?
    private var cookie: LinkCookie?
    private var csrf = ""
    var base: URL? { transport?.base }
    var ready: Bool { transport != nil && cookie != nil && !csrf.isEmpty }

    func connect(base: URL, pin: String, cookie: LinkCookie) async throws {
        guard cookie.name == "codex_mobile_session", cookie.value.count >= 32 else { throw LinkError.message("会话凭据无效") }
        let candidate = PinnedAPI(base: base, pin: pin)
        do {
            let auth: JSONValue = try await candidate.json("/api/auth", cookie: cookie, csrf: "")
            guard auth["authenticated"].bool, !auth["csrf"].string.isEmpty else { throw LinkError.message("设备会话已失效") }
            let bootstrap: JSONValue = try await candidate.json("/api/native/v1/bootstrap", cookie: cookie, csrf: "")
            guard bootstrap["apiVersion"].int == 1 else { throw LinkError.message("请升级 Mac 网关以支持原生客户端") }
            transport?.close(); transport = candidate; self.cookie = cookie; csrf = auth["csrf"].string
            generation += 1
        } catch { candidate.close(); throw error }
    }
    func clear() { transport?.close(); transport = nil; cookie = nil; csrf = ""; generation += 1 }
    func request<T: Decodable>(_ path: String, query: [String: String] = [:], body: JSONValue? = nil) async throws -> T {
        guard let transport, let cookie else { throw LinkError.message("尚未连接 Mac") }
        return try await transport.json(path, query: query, cookie: cookie, csrf: csrf, body: body)
    }
    func value(_ path: String, query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        try await request(path, query: query, body: body)
    }
    func upload(_ path: String, query: [String: String], data: Data) async throws -> JSONValue {
        guard let transport, let cookie else { throw LinkError.message("尚未连接 Mac") }
        let (bytes, _) = try await transport.nativeRequest(path, query: query, cookie: cookie, csrf: csrf, payload: data, contentType: "application/octet-stream")
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }
    func download(_ path: String, query: [String: String], name: String) async throws -> URL {
        guard let transport, let cookie else { throw LinkError.message("尚未连接 Mac") }
        let (bytes, _) = try await transport.nativeRequest(path, query: query, cookie: cookie, csrf: csrf)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent.isEmpty ? "download" : URL(fileURLWithPath: name).lastPathComponent)
        try bytes.write(to: file, options: .atomic); return file
    }
}

extension PinnedAPI {
    func nativeRequest(_ path: String, query: [String: String] = [:], cookie: LinkCookie, csrf: String,
                       payload: Data? = nil, contentType: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/api/"), !path.contains(".."), !path.contains("?") else { throw LinkError.message("接口路径无效") }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, sameOrigin(base, url) else { throw LinkError.message("接口地址不匹配") }
        var request = URLRequest(url: url); request.timeoutInterval = 55
        request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
        request.setValue("CodexLink/iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpMethod = "POST"; request.httpBody = payload
            request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 24 * 1024 * 1024 else { throw LinkError.message("响应过大或格式无效") }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw LinkError.message(error?["error"].string.isEmpty == false ? error!["error"].string : "网关请求失败（\(http.statusCode)）")
        }
        return (data, http)
    }
    func json<T: Decodable>(_ path: String, query: [String: String] = [:], cookie: LinkCookie, csrf: String,
                            body: JSONValue? = nil) async throws -> T {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let (data, _) = try await nativeRequest(path, query: query, cookie: cookie, csrf: csrf, payload: payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
