import SwiftUI

struct WorkspaceEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let kind: String
    let bytes: Int?
    var id: String { path }
}
struct WorkspaceTreePage: Decodable {
    let root: String
    let path: String
    let entries: [WorkspaceEntry]
    let hasMore: Bool
    let limited: Bool
}
struct WorkspaceFilePreview: Decodable {
    let path: String
    let text: String
    let bytes: Int
    let truncated: Bool
    let previewable: Bool
    let revision: String?
}
struct WorkspaceChange: Decodable, Identifiable {
    let path: String
    let added: Int?
    let removed: Int?
    let untracked: Bool
    var id: String { path }
}
struct WorkspaceChanges: Decodable {
    let root: String
    let source: String
    let files: [WorkspaceChange]
    let limited: Bool
    let fileCount: Int
    let added: Int
    let removed: Int
}
struct WorkspacePatch: Decodable {
    let path: String
    let source: String
    let text: String
}
struct WorkspaceDocument: Identifiable {
    let path: String
    let text: String
    let isDiff: Bool
    let notice: String
    var revision: String? = nil
    var editable = false
    var id: String { path }
}

@MainActor
final class NativeWorkspaceBrowserModel: ObservableObject {
    let api: NativeAPI
    let session: LinkSession
    @Published private(set) var entries: [WorkspaceEntry] = []
    @Published private(set) var root = ""
    @Published private(set) var hasMore = false
    @Published private(set) var limited = false
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var changes: WorkspaceChanges?
    @Published private(set) var diffLoading = false
    @Published private(set) var diffError = ""
    @Published private(set) var opening: String?
    @Published var document: WorkspaceDocument?
    @Published var openError = ""
    private var filesGeneration = 0
    private var changesGeneration = 0
    private var documentGeneration = 0
    private var loadedFilesKey = ""
    private var nextOffset = 0
    init(api: NativeAPI, session: LinkSession) { self.api = api; self.session = session }
    private func path(_ action: String) -> String { "/api/native/v1/threads/\(session.id)/workspace/\(action)" }
    func loadFiles(directory: String, query: String, more: Bool = false) async {
        filesGeneration += 1; let token = filesGeneration
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = directory + "\n" + query
        if loadedFilesKey != key { entries = []; hasMore = false; limited = false; nextOffset = 0 }
        loading = true; error = ""
        defer { if token == filesGeneration { loading = false } }
        do {
            if !query.isEmpty { try await Task.sleep(nanoseconds: 300_000_000) }
            var params = ["host": session.host]
            if query.isEmpty { params["path"] = directory; params["offset"] = String(more ? nextOffset : 0) }
            else { params["q"] = query }
            let page: WorkspaceTreePage = try await api.request(path(query.isEmpty ? "tree" : "search"), query: params)
            guard !Task.isCancelled, token == filesGeneration else { return }
            if more && loadedFilesKey == key {
                let ids = Set(entries.map(\.path)); entries += page.entries.filter { !ids.contains($0.path) }
                nextOffset += page.entries.count
            } else { entries = page.entries; nextOffset = page.entries.count }
            root = page.root; hasMore = page.hasMore; limited = page.limited; loadedFilesKey = key
        } catch { if !Task.isCancelled && token == filesGeneration { self.error = error.localizedDescription } }
    }
    func loadChanges(source: String) async {
        changesGeneration += 1; let token = changesGeneration
        if changes?.source != source { changes = nil }
        diffLoading = true; diffError = ""
        defer { if token == changesGeneration { diffLoading = false } }
        do {
            let value: WorkspaceChanges = try await api.request(path("changes"), query: ["host": session.host, "source": source])
            guard !Task.isCancelled, token == changesGeneration else { return }
            root = value.root; changes = value
        } catch { if !Task.isCancelled && token == changesGeneration { diffError = error.localizedDescription } }
    }
    func open(_ relativePath: String, diffSource: String? = nil) async {
        documentGeneration += 1; let token = documentGeneration
        opening = relativePath; openError = ""
        defer { if token == documentGeneration { opening = nil } }
        do {
            let value: WorkspaceDocument
            if let source = diffSource {
                let patch: WorkspacePatch = try await api.request(path("patch"), query: ["host": session.host, "path": relativePath, "source": source])
                value = WorkspaceDocument(path: relativePath, text: patch.text, isDiff: true,
                                          notice: patch.text.isEmpty ? "此文件当前没有文本差异，请刷新差异列表。" : "")
            } else {
                let preview: WorkspaceFilePreview = try await api.request(path("file"), query: ["host": session.host, "path": relativePath])
                value = WorkspaceDocument(path: relativePath, text: preview.text, isDiff: false,
                                          notice: !preview.previewable ? "此文件不是 UTF-8 文本，暂不支持预览。" : preview.truncated ? "仅显示前 128 KiB，完整文件请在 Mac 查看。" : "",
                                          revision: preview.revision, editable: preview.previewable && !preview.truncated && preview.revision != nil)
            }
            guard !Task.isCancelled, token == documentGeneration else { return }
            document = value
        } catch { if !Task.isCancelled && token == documentGeneration { openError = error.localizedDescription } }
    }
}

struct NativeWorkspaceBrowser: View {
    @StateObject private var model: NativeWorkspaceBrowserModel
    let onInsert: (String) -> Void
    let canEdit: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "files"
    @State private var directory = ""
    @State private var query = ""
    @State private var source = "unstaged"
    init(api: NativeAPI, session: LinkSession, canEdit: Bool = false, onInsert: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: NativeWorkspaceBrowserModel(api: api, session: session)); self.onInsert = onInsert; self.canEdit = canEdit
    }
    private var requestKey: String { [tab, directory, query, source].joined(separator: "\n") }
    var body: some View {
        NavigationStack {
            browserContent
            .navigationTitle("工作区").navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .task(id: requestKey) { await refresh() }
            .navigationDestination(isPresented: Binding(get: { model.document != nil }, set: { if !$0 { model.document = nil } })) { documentDestination }
            .alert("无法打开文件", isPresented: Binding(get: { !model.openError.isEmpty }, set: { if !$0 { model.openError = "" } })) {
                Button("好", role: .cancel) {}
            } message: { Text(model.openError) }
        }
    }
    private var browserContent: some View {
        VStack(spacing: 0) {
            Picker("工作区视图", selection: $tab) { Text("文件").tag("files"); Text("变更").tag("changes") }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10).accessibilityIdentifier("native.workspace.tabs")
            if tab == "files" { fileList } else { changeList }
        }
    }
    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新工作区") }
    }
    @ViewBuilder private var documentDestination: some View {
        if let document = model.document {
            NativeWorkspaceDocument(document: document, api: model.api, session: model.session, canEdit: canEdit, canComment: document.isDiff) { text in
                onInsert(text); dismiss()
            }
        }
    }
    private var fileList: some View {
        List {
            Section {
                TextField("搜索文件名或相对路径", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("native.workspace.search")
                if !directory.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { directory = directory.split(separator: "/").dropLast().joined(separator: "/") } label: { Label("上一级", systemImage: "arrow.up") }
                }
                Text(query.isEmpty ? directory.isEmpty ? "工作区根目录" : directory : "在整个工作区中搜索").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                if !model.error.isEmpty { errorRow(model.error) }
                ForEach(model.entries) { entry in
                    Button {
                        if entry.kind == "directory" { directory = entry.path; query = "" }
                        else if entry.kind == "file" { Task { await model.open(entry.path) } }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.kind == "directory" ? "folder" : entry.kind == "file" ? "doc.text" : "link").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).foregroundStyle(.primary)
                                if !query.isEmpty { Text(entry.path).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if model.opening == entry.path { ProgressView() }
                            else if entry.kind == "directory" { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(entry.kind == "unavailable").accessibilityIdentifier("native.workspace.entry.\(entry.path)")
                    .contextMenu {
                        Button("复制路径", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
                        Button("将路径带回输入框", systemImage: "text.badge.plus") { insertPath(entry.path) }
                    }
                }
                if model.loading { ProgressView().frame(maxWidth: .infinity) }
                else if model.entries.isEmpty && model.error.isEmpty { Text(query.isEmpty ? "此目录为空" : "没有匹配的文件").foregroundStyle(.secondary) }
                if model.hasMore { Button("加载更多文件") { Task { await model.loadFiles(directory: directory, query: query, more: true) } }.disabled(model.loading) }
                if model.limited { Text("已达到搜索或目录扫描上限，请缩小范围。").font(.caption).foregroundStyle(.secondary) }
            }
            if !model.root.isEmpty { Section { Text(model.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
        }.listStyle(.insetGrouped).refreshable { await refresh() }
    }
    private var changeList: some View {
        List {
            Section {
                Picker("差异来源", selection: $source) { Text("未暂存").tag("unstaged"); Text("已暂存").tag("staged") }.pickerStyle(.segmented)
                if let changes = model.changes {
                    HStack { Text("\(changes.fileCount) 个文件"); Spacer(); Text("+\(changes.added)").foregroundStyle(.green); Text("−\(changes.removed)").foregroundStyle(.red) }.font(.subheadline)
                }
            }
            Section {
                if !model.diffError.isEmpty { errorRow(model.diffError) }
                if model.diffLoading { ProgressView().frame(maxWidth: .infinity) }
                ForEach(model.changes?.files ?? []) { file in
                    Button { Task { await model.open(file.path, diffSource: file.untracked ? nil : source) } } label: {
                        HStack(alignment: .top) {
                            Image(systemName: file.untracked ? "doc.badge.plus" : "doc.text.magnifyingglass").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.path).foregroundStyle(.primary)
                                if file.untracked { Text("未跟踪 · 查看文件").font(.caption).foregroundStyle(.secondary) }
                                else if file.added == nil { Text("二进制文件").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if model.opening == file.path { ProgressView() }
                            else if let added = file.added, let removed = file.removed { Text("+\(added) −\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("native.workspace.change.\(file.path)")
                }
                if let changes = model.changes {
                    if changes.files.isEmpty && !model.diffLoading { Text("没有\(source == "staged" ? "已暂存" : "未暂存")变更").foregroundStyle(.secondary) }
                    if changes.limited { Text("仅显示前 200 个文件，请在 Mac 查看完整列表。").font(.caption).foregroundStyle(.secondary) }
                }
            } footer: { Text("只读查看当前工作目录的变更，不会暂存、提交或丢弃文件。") }
        }.listStyle(.insetGrouped).refreshable { await refresh() }
    }
    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { NativeNotice(text: error, isError: true); Button("重试") { Task { await refresh() } } }
    }
    private func insertPath(_ path: String) { onInsert(path); dismiss() }
    private func refresh() async {
        if tab == "files" { await model.loadFiles(directory: directory, query: query) }
        else { await model.loadChanges(source: source) }
    }
}

struct NativeWorkspaceDocument: View {
    let document: WorkspaceDocument
    let api: NativeAPI
    let session: LinkSession
    let canEdit: Bool
    let canComment: Bool
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.diffLineWrapping") private var wrapsLines = true
    @State private var comment = false
    @State private var previewMode = "source"
    @State private var editing = false
    @State private var draft: String
    @State private var baseline: String
    @State private var revision: String?
    @State private var busy = false
    @State private var error = ""
    @State private var status = ""
    @State private var pending = ""
    init(document: WorkspaceDocument, api: NativeAPI, session: LinkSession, canEdit: Bool, canComment: Bool, onInsert: @escaping (String) -> Void) {
        self.document = document; self.api = api; self.session = session; self.canEdit = canEdit; self.canComment = canComment; self.onInsert = onInsert
        _draft = State(initialValue: document.text); _baseline = State(initialValue: document.text); _revision = State(initialValue: document.revision)
    }
    private var dirty: Bool { draft != baseline }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(document.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("将路径带回输入框", systemImage: "text.badge.plus") { leave("insert") }
                    if canComment { Button("评论此文件", systemImage: "text.bubble") { comment = true } }
                    if editing { Text(dirty ? "未保存" : "已保存").font(.caption).foregroundStyle(.secondary) }
                }.font(.caption).buttonStyle(.bordered)
                NativeNotice(text: document.notice)
                NativeNotice(text: error, isError: true)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("native.workspace.save.status") }
            }.padding(.horizontal, 16).padding(.top, 12)
            if document.isDiff { ScrollView { NativeDiff(content: document.text, wrapsLines: wrapsLines).padding(16) } }
            else {
                Picker("文件视图", selection: $previewMode) { Text("源码").tag("source"); Text("渲染").tag("rendered") }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                if previewMode == "rendered" && NativeCodeLanguages.name(document.path) == "markdown" {
                    ScrollView { NativeMarkdown(text: draft).padding(16) }
                } else { NativeCodeView(text: $draft, language: document.path, editable: editing && !busy, wrapsLines: wrapsLines, identifier: "native.workspace.editor") }
            }
        }
        .navigationTitle(document.isDiff ? "文件差异" : editing ? "编辑文件" : "文件预览").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("返回") { leave("back") }.disabled(busy) }
            ToolbarItemGroup(placement: .primaryAction) {
                if canEdit && document.editable && !document.isDiff {
                    if editing { Button("保存") { Task { await save() } }.disabled(busy || !dirty).accessibilityIdentifier("native.workspace.save") }
                    else { Button("编辑") { editing = true }.accessibilityIdentifier("native.workspace.edit") }
                }
                Menu {
                    Button("复制路径", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.path }
                    Button("复制全文", systemImage: "doc.on.doc") { UIPasteboard.general.string = draft }
                    Toggle("自动换行", isOn: $wrapsLines)
                    if !document.isDiff { Button("重新读取文件", systemImage: "arrow.clockwise") { leave("reload") }.disabled(busy) }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("文件操作")
            }
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = "" } }), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { let action = pending; pending = ""; proceed(action) }
            Button("继续编辑", role: .cancel) { pending = "" }
        }
        .interactiveDismissDisabled(dirty || busy)
        .sheet(isPresented: $comment) { NativeDiffComment(path: document.path, onInsert: onInsert) }
    }
    private func leave(_ action: String) { if dirty { pending = action } else { proceed(action) } }
    private func proceed(_ action: String) {
        if action == "insert" { onInsert(document.path) }
        else if action == "reload" { Task { await reload() } }
        else { dismiss() }
    }
    private func save() async {
        guard let revision, !busy else { return }
        busy = true; error = ""; status = ""; defer { busy = false }
        let submitted = draft
        do {
            let result: WorkspaceFilePreview = try await api.request("/api/native/v1/threads/\(session.id)/workspace/file", query: ["host": session.host], body: json(["path": string(document.path), "text": string(submitted), "revision": string(revision)]))
            baseline = submitted; self.revision = result.revision; status = "已保存到 Mac 工作区"
        } catch { self.error = error.localizedDescription }
    }
    private func reload() async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            let result: WorkspaceFilePreview = try await api.request("/api/native/v1/threads/\(session.id)/workspace/file", query: ["host": session.host, "path": document.path])
            guard result.previewable, !result.truncated else { throw LinkError.message("文件已变为二进制或超过大小限制，草稿保留。") }
            draft = result.text; baseline = result.text; revision = result.revision; status = "已重新读取 Mac 文件"
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeDiffComment: View {
    let path: String
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var line = ""
    @State private var text = ""
    private var validLine: Bool { line.isEmpty || Int(line).map { $0 > 0 } == true }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(path).font(.caption).textSelection(.enabled); TextField("行号（可选）", text: $line).keyboardType(.numberPad) }
                Section("评论") { TextEditor(text: $text).frame(minHeight: 140).accessibilityIdentifier("native.diff.comment") }
                Section { Text("添加到当前输入草稿，由你确认后发送。").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("评论文件差异").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("带回输入框") { onInsert("请查看 " + path + (line.isEmpty ? "" : ":" + line) + "：\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(!validLine || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("native.diff.comment.insert")
                }
            }
        }
    }
}
