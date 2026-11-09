import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    let api: NativeAPI
    @Published var sessions: [LinkSession] = []
    @Published var projects: [LinkProject] = []
    @Published var selected: LinkSession? {
        didSet {
            if let row = selected, row.identity != oldValue?.identity, row.unread == true {
                Task { do { try await markRead(row) } catch { self.error = error.localizedDescription } }
            }
        }
    }
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

    func load(more: Bool = false, refresh: Bool = false) async {
        guard api.ready else { return }
        revision += 1; let token = revision
        loading = true; error = ""
        defer { if token == revision { loading = false } }
        let offset = more ? sessions.count : 0
        do {
            var params = ["q": query, "archived": String(archived), "hidden": String(hidden), "scope": desktopOnly ? "desktop" : "all",
                          "internal": String(includeInternal), "sort": sort, "limit": "100", "offset": String(offset)]
            if refresh { params["refresh"] = "true" }
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
        _ = try await api.value("/api/sessions/\(row.id)/rename", query: ["host": row.host], body: json(["title": string(name)])); await load(refresh: true)
    }
    func archive(_ row: LinkSession) async throws {
        _ = try await api.value("/api/workspace/archive", body: json(["id": string(row.id), "host": string(row.host), "archived": .bool(!(row.archived ?? false)), "confirmed": .bool(true)])); await load()
    }
    private var forkAttempts: [String: (key: String, version: JSONValue, id: String)] = [:]
    private func markRead(_ row: LinkSession) async throws {
        _ = try await api.value("/api/workspace/preferences", body: json(["sessions": .array([json(["id": string(row.id), "host": string(row.host)])]), "changes": json(["unread": .bool(false)])]))
        if let index = sessions.firstIndex(where: { $0.identity == row.identity }) { sessions[index].unread = false }
        if selected?.identity == row.identity { selected?.unread = false }
    }
    func fork(_ row: LinkSession) async throws {
        var before: String?, epoch: String?
        while true {
            try Task.checkCancellation()
            var query = ["host": row.host, "limit": "100"]
            if let before { query["before"] = before }
            let page: TimelinePage = try await api.request("/api/native/v1/threads/\(row.id)/timeline", query: query)
            if let epoch, epoch != page.epoch || page.reset == true { throw LinkError.message("会话内容已变化，请刷新后重试") }
            epoch = page.epoch
            if let latest = page.rows.reversed().first(where: { $0.forkable == true }) {
                let key = page.epoch + "." + latest.key
                if forkAttempts[row.identity]?.key != key || forkAttempts[row.identity]?.version != latest.version {
                    forkAttempts[row.identity] = (key, latest.version, UUID().uuidString.lowercased())
                }
                let body = json(["action": string("fork"), "id": string(forkAttempts[row.identity]!.id), "key": string(key), "version": latest.version])
                let result = try await api.value("/api/sessions/\(row.id)/message-action", query: ["host": row.host], body: body)
                guard result["status"].string == "created" else { throw LinkError.message("分支结果未确认，请刷新列表检查后再重试") }
                await load(refresh: true)
                let child: LinkSession = try await api.request("/api/session-meta/\(result["id"].string)", query: ["host": row.host])
                selected = child
                return
            }
            guard page.hasMore == true, let next = page.before, next != before else { throw LinkError.message("没有可分支的已完成轮次；请打开对话加载更早记录") }
            before = page.before
        }
    }
    func copyMarkdown(_ row: LinkSession) async throws -> String {
        var output = ["# \(row.title)", "", "- 项目：\(row.projectName ?? "")", "- 工作目录：\(row.cwd ?? "")", ""]
        var collected: [NativeRow] = []
        var epoch: String?, before: String?
        repeat {
            try Task.checkCancellation()
            var query = ["host": row.host, "limit": "100"]
            if let before { query["before"] = before }
            let page: TimelinePage = try await api.request("/api/native/v1/threads/\(row.id)/timeline", query: query)
            if let epoch, epoch != page.epoch || page.reset == true { throw LinkError.message("会话内容已变化，请重新复制") }
            epoch = page.epoch
            collected = page.rows + collected
            if page.hasMore == true && (page.before == nil || page.before == before) { throw LinkError.message("更早记录尚未载入，请打开对话加载历史后再复制") }
            before = page.hasMore == true ? page.before : nil
        } while before != nil
        var seen = Set<String>()
        for item in collected where seen.insert(item.key).inserted {
            var text = item.text
            if item.truncated == true {
                var offset = 0, full = ""
                while true {
                    try Task.checkCancellation()
                    let detail: JSONValue = try await api.value("/api/native/v1/threads/\(row.id)/detail", query: [
                        "host": row.host, "key": (epoch ?? "") + "." + item.key, "offset": String(offset), "version": item.version.identifier
                    ])
                    guard detail["version"] == item.version, detail["offset"].int == offset else { throw LinkError.message("消息已更新，请重新复制") }
                    full += detail["text"].string
                    if detail["next"] == .null { break }
                    guard detail["next"].int > offset else { throw LinkError.message("消息详情不完整，请重新复制") }
                    offset = detail["next"].int
                }
                text = full
            }
            let heading = item.role == "user" ? "## 用户" : item.role == "assistant" ? "## Codex" : "### \(item.title ?? item.kind ?? "工具")"
            if item.isProcess {
                var fence = "```"
                while text.contains(fence) { fence += "`" }
                text = fence + (item.kind == "fileChange" ? "diff" : "text") + "\n" + text + "\n" + fence
            }
            output += [heading, "", text, ""]
        }
        return output.joined(separator: "\n")
    }
    func permanentlyDelete(_ row: LinkSession) async throws {
        _ = try await api.value("/api/workspace/delete", body: json(["id": string(row.id), "host": string(row.host), "confirmed": .bool(true)]))
        if selected?.identity == row.identity { selected = nil }
        await load()
    }
    func updateProject(_ project: LinkProject, changes: [String: JSONValue]) async throws {
        _ = try await api.value("/api/workspace/projects", body: json(["action": string("update"), "key": string(project.key), "changes": json(changes)])); await load()
    }
    func clear() { revision += 1; sessions = []; projects = []; selected = nil; project = nil; forkAttempts = [:]; error = ""; loading = false }
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
    @Published var convertingCLI = false
    @Published var conversionError = ""
    @Published var hasMore = false
    @Published var draft = ChatDraft() { didSet { scheduleDraftSave() } }
    @Published private(set) var draftStorageError = ""
    @Published var logView = false
    @Published var revision = 0
    private var drafts: [String: ChatDraft] = [:]
    private var epoch = ""
    private var sequence = -1
    private var before: String?
    private var loadedLogView: Bool?
    private var generation = 0
    private var details: [String: (version: JSONValue, text: String, next: Int?)] = [:]
    private var detailLoads: [String: Task<Void, Error>] = [:]
    private var diffStats: [String: (version: JSONValue, value: NativeDiffStats)] = [:]
    private var diffLoads = Set<String>()
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
    func fileChangeStats(_ row: NativeRow) -> NativeDiffStats? { diffStats[row.key]?.version == row.version ? diffStats[row.key]?.value : nil }
    func loadFileChangeStats(_ row: NativeRow) async {
        guard row.kind == "fileChange", fileChangeStats(row) == nil else { return }
        let token = generation, currentEpoch = epoch
        let key = "\(token)|\(epoch)|\(row.key)|\(row.version.identifier)"
        guard diffLoads.insert(key).inserted else { return }
        defer { diffLoads.remove(key) }
        do {
            while rowHasMore(row) {
                try Task.checkCancellation()
                try await expand(row)
            }
            let text = rowText(row)
            let value = await Task.detached(priority: .utility) { NativeDiffStats(NativeDiffDocument(text)) }.value
            guard !Task.isCancelled, token == generation, currentEpoch == epoch,
                  rows.contains(where: { $0.key == row.key && $0.version == row.version }) else { return }
            diffStats[row.key] = (row.version, value); revision += 1
        } catch { /* Opening the detail page offers an explicit retry on failure. */ }
    }
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
        let canResumeTimeline = target != nil && session?.identity == target?.identity && loadedLogView == logView && sequence >= 0
        generation += 1; let token = generation
        session = target
        error = ""; pollingError = ""
        if !canResumeTimeline {
            rows = []; files = []; details = [:]; diffStats = [:]; meta = .null; capabilities = .null; epoch = ""; sequence = -1; before = nil; notice = ""; responded = []; loadingOlder = false
            loadedLogView = nil
            isRestoringDraft = true
            draft = target.map { restoredDraft(for: $0.identity) } ?? ChatDraft()
            isRestoringDraft = false
        }
        guard target != nil else { loading = false; return }
        if canResumeTimeline {
            loading = false
        } else {
            loading = true
            do {
                let page: TimelinePage = try await api.request(path("timeline"), query: params())
                guard token == generation, !Task.isCancelled else { return }
                apply(page, replace: true); loadedLogView = logView
                await sendPrimedDraftIfReady()
                if let target, target.readOnly == true, target.host == "local", target.originator == "codex-tui" {
                    Task { await convertCLIIfNeeded(target) }
                }
            } catch { if !Task.isCancelled && token == generation { self.pollingError = error.localizedDescription } }
            if token == generation { loading = false }
        }
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

    func retryCLIConversion() async {
        guard let target = session else { return }
        await convertCLIIfNeeded(target)
    }

    private func convertCLIIfNeeded(_ target: LinkSession) async {
        guard session?.identity == target.identity, target.originator == "codex-tui", !convertingCLI else { return }
        convertingCLI = true; conversionError = ""
        defer { convertingCLI = false }
        do {
            let updated: LinkSession = try await api.request(
                "/api/sessions/\(target.id)/convert", query: ["host": target.host], body: json([:])
            )
            guard session?.identity == target.identity else { return }
            guard updated.readOnly != true else { throw LinkError.message("转换未能启用会话控制") }
            sequence = -1
            session = updated
            Task { await run(updated) }
        } catch {
            if session?.identity == target.identity { conversionError = error.localizedDescription }
        }
    }
    private func apply(_ page: TimelinePage, replace: Bool, older: Bool = false) {
        if replace { rows = []; details = [:]; diffStats = [:]; epoch = page.epoch }
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
    func older(beforeApply: (() -> Void)? = nil) async {
        guard hasMore, !loadingOlder, session != nil else { return }
        let token = generation; loadingOlder = true
        defer { if token == generation { loadingOlder = false } }
        do {
            var query = params(); query["limit"] = "50"; query["before"] = before
            let page: TimelinePage = try await api.request(path("timeline"), query: query)
            guard token == generation, !Task.isCancelled else { return }
            beforeApply?()
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { apply(page, replace: page.reset == true, older: true) }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    func expand(_ row: NativeRow) async throws {
        guard session != nil, rows.contains(where: { $0.key == row.key && $0.version == row.version }) else { throw CancellationError() }
        let token = generation, currentEpoch = epoch
        let offset = details[row.key]?.version == row.version ? details[row.key]?.next ?? 0 : 0
        let key = "\(generation)|\(epoch)|\(row.key)|\(row.version.identifier)|\(offset)"
        if let existing = detailLoads[key] { try await existing.value; return }
        let task = Task { try await expandPage(row, generation: token, epoch: currentEpoch) }
        detailLoads[key] = task
        defer { detailLoads.removeValue(forKey: key) }
        try await task.value
    }
    private func expandPage(_ row: NativeRow, generation token: Int, epoch currentEpoch: String) async throws {
        try Task.checkCancellation()
        guard token == generation, currentEpoch == epoch, let target = session else { throw CancellationError() }
        let offset = details[row.key]?.version == row.version ? details[row.key]?.next ?? 0 : 0
        var query = params(); query["key"] = currentEpoch + "." + row.key; query["offset"] = String(offset); query["version"] = row.version.identifier
        let result = try await api.value("/api/native/v1/threads/\(target.id)/detail", query: query)
        try Task.checkCancellation()
        guard token == generation, currentEpoch == epoch, session?.identity == target.identity, result["version"] == row.version, result["offset"].int == offset,
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
    func send(mode: String? = nil) async {
        guard canSend, let target = session else { return }
        let apiGeneration = api.generation
        let sendMode = mode ?? draft.sendMode
        guard ["send", "queue", "steer"].contains(sendMode) else { return }
        var fields: [String: JSONValue] = ["text": string(draft.text), "mode": string(sendMode), "skills": .array(draft.skills.map(string)),
            "attachments": .array(draft.attachments.map { string($0.id) }), "uiLocale": string("zh-CN")]
        if sendMode != "steer" { fields["workMode"] = string(draft.workMode) }
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
    func upload(_ url: URL, name: String? = nil) async throws {
        guard !readOnly, let target = session else { throw LinkError.message("只读历史无法添加附件") }
        let token = generation
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw LinkError.message("附件需为 1 字节至 20 MB") }
        let data = try Data(contentsOf: url)
        let id = UUID().uuidString.lowercased()
        let filename = name ?? url.lastPathComponent
        let result = try await api.upload("/api/sessions/\(target.id)/uploads", query: ["host": target.host, "id": id, "name": filename], data: data)
        guard token == generation else { return }
        let attachment = result["attachment"] == .null ? result : result["attachment"]
        draft.attachments.append(PendingAttachment(id: attachment["id"].string.isEmpty ? id : attachment["id"].string, name: filename, size: size))
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
    func clear() { detailLoads.values.forEach { $0.cancel() }; detailLoads = [:]; diffLoads = []; details = [:]; diffStats = [:]; flushDraft(); draftSaveTask?.cancel(); draftSaveTask = nil; generation += 1; sending = []; autoSend = []; drafts = [:]; session = nil; draft = ChatDraft(); rows = []; meta = .null; files = []; loadedLogView = nil; logView = false }
}
