import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    let api: NativeAPI
    @Published var sessions: [LinkSession] = []
    @Published var projects: [LinkProject] = []
    @Published var selected: LinkSession?
    @Published var project: LinkProject?
    @Published var query = ""
    @Published var archived = false
    @Published var hidden = false
    @Published var desktopOnly = false
    @Published var includeInternal = false
    @Published var sort = "updated"
    @Published var loading = false
    @Published var hasMore = false
    @Published var total = 0
    @Published var error = ""
    @Published var warnings: [String] = []
    private var revision = 0
    init(api: NativeAPI) { self.api = api }
    var filterID: String { [query, String(archived), String(hidden), String(desktopOnly), String(includeInternal), sort, project?.key ?? "", String(api.generation)].joined(separator: "\n") }

    func load(more: Bool = false) async {
        guard api.ready else { return }
        revision += 1; let token = revision
        loading = true; error = ""
        defer { if token == revision { loading = false } }
        let offset = more ? sessions.count : 0
        do {
            var params = ["q": query, "archived": String(archived), "hidden": String(hidden), "scope": desktopOnly ? "desktop" : "all",
                          "internal": String(includeInternal), "sort": sort, "limit": "100", "offset": String(offset)]
            if let project { params["project"] = project.key }
            let result: SessionPage = try await api.request("/api/sessions", query: params)
            guard token == revision, !Task.isCancelled else { return }
            sessions = more ? sessions + result.sessions.filter { r in !sessions.contains { $0.identity == r.identity } } : result.sessions
            projects = result.projects; total = result.total; hasMore = result.hasMore; warnings = result.warnings ?? []
        } catch { if token == revision && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func selectProject(_ value: LinkProject?) { project = value }
    func preferences(_ rows: [LinkSession], changes: [String: JSONValue]) async throws {
        _ = try await api.value("/api/workspace/preferences", body: json(["sessions": .array(rows.map { json(["id": string($0.id), "host": string($0.host)]) }), "changes": json(changes)]))
        await load()
    }
    func rename(_ row: LinkSession, name: String) async throws {
        _ = try await api.value("/api/sessions/\(row.id)/rename", query: ["host": row.host], body: json(["title": string(name)])); await load()
    }
    func archive(_ row: LinkSession) async throws {
        _ = try await api.value("/api/workspace/archive", body: json(["id": string(row.id), "host": string(row.host), "archived": .bool(!(row.archived ?? false)), "confirmed": .bool(true)])); await load()
    }
    func updateProject(_ project: LinkProject, changes: [String: JSONValue]) async throws {
        _ = try await api.value("/api/workspace/projects", body: json(["action": string("update"), "key": string(project.key), "changes": json(changes)])); await load()
    }
    func clear() { revision += 1; sessions = []; projects = []; selected = nil; project = nil; error = ""; loading = false }
}

struct PendingAttachment: Identifiable {
    let id: String
    let name: String
    let size: Int
}

@MainActor
final class ChatModel: ObservableObject {
    let api: NativeAPI
    @Published var session: LinkSession?
    @Published var rows: [NativeRow] = []
    @Published var meta: JSONValue = .null
    @Published var capabilities: JSONValue = .null
    @Published var files: [JSONValue] = []
    @Published var loading = false
    @Published private var sending = Set<String>()
    var busy: Bool { session.map { sending.contains($0.identity) } ?? false }
    @Published var loadingOlder = false
    @Published var error = ""
    @Published var notice = ""
    @Published var pollingError = ""
    @Published var hasMore = false
    @Published var draft = ChatDraft() { didSet { scheduleDraftSave() } }
    @Published private(set) var draftStorageError = ""
    @Published var logView = false
    @Published var revision = 0
    private var drafts: [String: ChatDraft] = [:]
    private var epoch = ""
    private var sequence = -1
    private var before: String?
    private var generation = 0
    private var details: [String: (version: JSONValue, text: String, next: Int?)] = [:]
    private var responded = Set<String>()
    private var autoSend = Set<String>()
    private let draftStore: DraftStore
    private var draftScope: String?
    private var draftSaveTask: Task<Void, Never>?
    private var isRestoringDraft = false
    private var unreadableDrafts = Set<String>()
    init(api: NativeAPI, draftStore: DraftStore = .shared, draftScope: String? = nil) {
        self.api = api; self.draftStore = draftStore; self.draftScope = draftScope
    }
    func setDraftScope(_ scope: String?) {
        guard scope != draftScope else { return }
        flushDraft(); clear(); draftScope = scope
        unreadableDrafts = []; draftStorageError = ""
    }
    private func scheduleDraftSave() {
        guard !isRestoringDraft else { return }
        draftSaveTask?.cancel()
        guard let session, draftScope != nil else { return }
        // Only an actual composer edit may replace an unreadable saved draft.
        unreadableDrafts.remove(session.identity)
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.flushDraft()
        }
    }
    func flushDraft() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard let session else { return }
        saveDraft(draft, for: session.identity)
    }
    private func saveDraft(_ value: ChatDraft, for identity: String) {
        drafts[identity] = value
        guard let draftScope, !unreadableDrafts.contains(identity) else { return }
        do { try draftStore.save(value, scope: draftScope, identity: identity); draftStorageError = "" }
        catch { draftStorageError = "本机草稿未保存：" + error.localizedDescription }
    }
    private func restoredDraft(for identity: String) -> ChatDraft {
        if let value = drafts[identity] { return value }
        guard let draftScope else { return ChatDraft() }
        do { return try draftStore.load(scope: draftScope, identity: identity) ?? ChatDraft() }
        catch { unreadableDrafts.insert(identity); draftStorageError = "本机草稿无法读取：" + error.localizedDescription; return ChatDraft() }
    }
    func forgetDrafts() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        if let draftScope {
            do { try draftStore.forget(scope: draftScope); draftStorageError = "" }
            catch { draftStorageError = "本机草稿未能清除：" + error.localizedDescription }
        }
        // Detach before clearing so no delayed write can recreate forgotten data.
        draftScope = nil; unreadableDrafts = []; clear()
    }
    var readOnly: Bool { capabilities["readOnly"].bool || logView || session?.readOnly == true }
    var connected: Bool { meta["connected"].bool && !readOnly }
    var running: Bool { meta["status"].string == "active" }
    var canSend: Bool { connected && !busy && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty) }
    var requests: [JSONValue] { readOnly ? [] : meta["requests"].array }
    var visibleRows: [NativeRow] { rows.filter { $0.kind != "reasoning" } }
    func cursor(for row: NativeRow) -> String { epoch + "." + row.key }
    func rowText(_ row: NativeRow) -> String { details[row.key]?.version == row.version ? details[row.key]!.text : row.text }
    func rowHasMore(_ row: NativeRow) -> Bool { if let detail = details[row.key], detail.version == row.version { return detail.next != nil }; return row.truncated == true }
    func wasResponded(_ request: JSONValue) -> Bool { responded.contains(request["id"].identifier) }
    private func params() -> [String: String] { ["host": session?.host ?? "local", "view": logView ? "log" : "live"] }
    private func path(_ action: String) -> String { "/api/native/v1/threads/\(session!.id)/\(action)" }
    private func actionPath(_ action: String) -> String { "/api/sessions/\(session!.id)/\(action)" }
    func primeDraft(_ text: String, for target: LinkSession) {
        var value = restoredDraft(for: target.identity); value.text = text; saveDraft(value, for: target.identity)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { autoSend.insert(target.identity) }
    }
    private func sendPrimedDraftIfReady() async {
        guard let target = session, autoSend.contains(target.identity), canSend else { return }
        autoSend.remove(target.identity)
        await send()
    }

    func run(_ target: LinkSession?) async {
        flushDraft()
        generation += 1; let token = generation
        session = target; rows = []; files = []; details = [:]; meta = .null; capabilities = .null; epoch = ""; sequence = -1; before = nil; error = ""; pollingError = ""; notice = ""; responded = []; loadingOlder = false
        isRestoringDraft = true
        draft = target.map { restoredDraft(for: $0.identity) } ?? ChatDraft()
        isRestoringDraft = false
        guard target != nil else { loading = false; return }
        loading = true
        do { let page: TimelinePage = try await api.request(path("timeline"), query: params()); guard token == generation, !Task.isCancelled else { return }; apply(page, replace: true); await sendPrimedDraftIfReady() }
        catch { if !Task.isCancelled && token == generation { self.pollingError = error.localizedDescription } }
        if token == generation { loading = false }
        while !Task.isCancelled && token == generation {
            do {
                try await Task.sleep(nanoseconds: pollingError.isEmpty ? 1_200_000_000 : 3_000_000_000)
                var query = params(); query["after"] = String(sequence); query["epoch"] = epoch; query["start"] = before ?? ""
                let page: TimelinePage = try await api.request(path(sequence < 0 ? "timeline" : "changes"), query: query)
                guard token == generation, !Task.isCancelled else { return }
                pollingError = ""; apply(page, replace: page.reset == true || sequence < 0); await sendPrimedDraftIfReady()
            } catch is CancellationError { return }
            catch { if !Task.isCancelled && token == generation { self.pollingError = error.localizedDescription } }
        }
    }
    private func apply(_ page: TimelinePage, replace: Bool, older: Bool = false) {
        if replace { rows = []; details = [:]; epoch = page.epoch }
        var mapping = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        for row in page.rows { mapping[row.key] = row }
        let updated = mapping.values.sorted { $0.order == $1.order ? $0.key < $1.key : $0.order < $1.order }
        if rows != updated { rows = updated }
        if !older || replace { meta = page.meta; capabilities = page.capabilities; sequence = page.sequence }
        if replace || older { before = page.before; hasMore = page.hasMore ?? false }
        var artifacts = Dictionary(uniqueKeysWithValues: files.map { ($0["id"].string, $0) })
        for file in page.files ?? [] { artifacts[file["id"].string] = file }
        files = artifacts.values.sorted { $0["name"].string < $1["name"].string }
        revision += 1
    }
    func older() async {
        guard hasMore, !loadingOlder, session != nil else { return }
        let token = generation; loadingOlder = true
        defer { if token == generation { loadingOlder = false } }
        do {
            var query = params(); query["limit"] = "50"; query["before"] = before
            let page: TimelinePage = try await api.request(path("timeline"), query: query)
            guard token == generation, !Task.isCancelled else { return }
            apply(page, replace: page.reset == true, older: true)
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    func expand(_ row: NativeRow) async throws {
        let token = generation, offset = details[row.key]?.version == row.version ? details[row.key]?.next ?? 0 : 0
        var query = params(); query["key"] = epoch + "." + row.key; query["offset"] = String(offset); query["version"] = row.version.identifier
        let result = try await api.value(path("detail"), query: query)
        guard token == generation, result["version"] == row.version, result["offset"].int == offset,
              rows.contains(where: { $0.key == row.key && $0.version == row.version }) else { throw LinkError.message("内容已变化，请重新展开") }
        let text = (offset == 0 ? "" : details[row.key]?.text ?? "") + result["text"].string
        details[row.key] = (row.version, text, result["next"] == .null ? nil : result["next"].int); revision += 1
    }
    func action(_ action: String, body: JSONValue = .object([:])) async throws -> JSONValue {
        guard !readOnly, session != nil else { throw LinkError.message("当前为只读历史") }
        return try await api.value(actionPath(action), query: ["host": session!.host], body: body)
    }
    func reconnect() async throws { _ = try await action("reconnect", body: json(["activate": .bool(true)])) }
    func stop() async throws { _ = try await action("stop") }
    func send() async {
        guard canSend, let target = session else { return }
        let apiGeneration = api.generation
        var fields: [String: JSONValue] = ["text": string(draft.text), "mode": string(draft.sendMode), "skills": .array(draft.skills.map(string)),
            "attachments": .array(draft.attachments.map { string($0.id) }), "uiLocale": string("zh-CN")]
        if draft.sendMode != "steer" { fields["workMode"] = string(draft.workMode) }
        let payload = json(fields)
        if draft.attempt?.payload != payload { draft.attempt = DraftSendAttempt(payload: payload, id: UUID().uuidString.lowercased()) }
        flushDraft()
        let submitted = draft
        fields["id"] = string(submitted.attempt!.id)
        sending.insert(target.identity); error = ""; notice = ""
        defer { sending.remove(target.identity) }
        do {
            let result = try await action("send", body: json(fields))
            guard api.ready, apiGeneration == api.generation else { return }
            let current = session?.identity == target.identity
            if result["status"].string == "unknown" || result["confirmed"] == .bool(false) {
                if current { notice = "发送结果未确认，草稿已保留。重试会沿用同一请求标识。" }; return
            }
            var latest = current ? draft : drafts[target.identity] ?? submitted
            // Do not erase text entered while the acknowledged request was in flight.
            if latest.text == submitted.text { latest.text = "" }
            let sentFiles = Set(submitted.attachments.map(\.id))
            latest.attachments.removeAll { sentFiles.contains($0.id) }
            if latest.attempt?.id == submitted.attempt?.id { latest.attempt = nil }
            latest.recoveryNotice = ""
            saveDraft(latest, for: target.identity)
            if current { draft = latest; notice = result["status"].string == "queued" ? "已加入待发送队列" : "消息已提交" }
        } catch { if session?.identity == target.identity { self.error = error.localizedDescription + "。草稿已保留，可重试同一请求。" } }
    }
    func upload(_ url: URL) async throws {
        guard !readOnly, let target = session else { throw LinkError.message("只读历史无法添加附件") }
        let token = generation
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw LinkError.message("附件需为 1 字节至 20 MB") }
        let data = try Data(contentsOf: url)
        let id = UUID().uuidString.lowercased()
        let result = try await api.upload("/api/sessions/\(target.id)/uploads", query: ["host": target.host, "id": id, "name": url.lastPathComponent], data: data)
        guard token == generation else { return }
        let attachment = result["attachment"] == .null ? result : result["attachment"]
        draft.attachments.append(PendingAttachment(id: attachment["id"].string.isEmpty ? id : attachment["id"].string, name: url.lastPathComponent, size: size))
    }
    func respond(_ request: JSONValue, response: JSONValue) async throws {
        let id = request["id"]
        guard !responded.contains(id.identifier) else { return }
        _ = try await action("respond", body: json(["requestId": id, "response": response]))
        responded.insert(id.identifier); revision += 1
    }
    func preserveDraft(_ text: String, for target: LinkSession) { primeDraft(text, for: target); autoSend.remove(target.identity) }
    @discardableResult func appendWorkspaceContext(_ text: String, for target: LinkSession) -> Bool {
        guard !readOnly, session?.identity == target.identity, !text.isEmpty else { return false }
        draft.text += (draft.text.isEmpty ? "" : "\n\n") + text
        flushDraft()
        return true
    }
    func clear() { flushDraft(); draftSaveTask?.cancel(); draftSaveTask = nil; generation += 1; sending = []; autoSend = []; drafts = [:]; session = nil; draft = ChatDraft(); rows = []; meta = .null; files = []; logView = false }
}
