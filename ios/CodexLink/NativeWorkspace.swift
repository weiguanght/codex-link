import SwiftUI

struct NativeLibraryView: View {
    @ObservedObject var model: WorkspaceModel
    let onSelect: (LinkSession) -> Void
    let onNewChat: () -> Void
    let onSettings: () -> Void
    @State private var newProject = false
    @State private var rename: LinkSession?
    @State private var renameProject: LinkProject?
    @State private var archive: LinkSession?
    @State private var name = ""
    @State private var error = ""
    @State private var selected = Set<String>()
    @State private var selecting = false
    @State private var showProjects = false
    @State private var projectSettings: LinkProject?
    @State private var agents = ""
    @State private var showAgents = false
    @State private var batchConfirm = false
    var body: some View {
        libraryList
        .listStyle(.plain).scrollDismissesKeyboard(.interactively)
        .searchable(text: $model.query, prompt: "搜索对话和项目")
        .navigationTitle("Codex Link").navigationBarTitleDisplayMode(.large)
        .toolbar { filterControls }
        .safeAreaInset(edge: .bottom) { batchControls }
        .refreshable { await model.load() }
        .sheet(isPresented: $newProject) { NativeProjectForm(model: model, initial: nil) }
        .sheet(item: $renameProject) { NativeProjectForm(model: model, initial: $0) }
        .sheet(item: $projectSettings) { project in NavigationStack { NativeCodexSettings(api: model.api, workspace: model, initialScope: project.key) } }
        .sheet(isPresented: $showAgents) { NavigationStack { NativeTextDocument(title: "AGENTS.md", text: agents).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showAgents = false } } } } }
        .sheet(item: $rename) { NativeSessionRename(model: model, row: $0) }
        .confirmationDialog("确认修改归档状态？", isPresented: Binding(get: { archive != nil }, set: { if !$0 { archive = nil } }), titleVisibility: .visible) {
            if let row = archive { Button(row.archived == true ? "取消归档" : "归档对话") { perform { try await model.archive(row) } } }
        } message: { Text("正在执行的任务需先结束。此操作会修改 Mac 上的对话归档状态。") }
        .confirmationDialog("修改 \(selected.count) 条对话的列表可见性？", isPresented: $batchConfirm, titleVisibility: .visible) {
            Button("确认") { let rows = model.sessions.filter { selected.contains($0.identity) }; perform { try await model.preferences(rows, changes: ["hidden": .bool(!model.hidden)]); selected = [] } }
        }
        .alert("操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好", role: .cancel) {} } message: { Text(error) }
    }
    private var libraryList: some View {
        List {
            Section {
                Button(action: onNewChat) { Label("新建对话", systemImage: "square.and.pencil").font(.body.weight(.medium)).padding(.vertical, 5) }.accessibilityIdentifier("native.newChat")
                Button { newProject = true } label: { Label("新建项目", systemImage: "folder.badge.plus").padding(.vertical, 5) }.accessibilityIdentifier("native.newProject")
            }.listRowSeparator(.hidden)
            if let project = model.project {
                Section {
                    Button { model.selectProject(nil) } label: { Label("全部对话", systemImage: "chevron.left") }
                    HStack { Image(systemName: "folder"); VStack(alignment: .leading, spacing: 4) { Text(project.name).font(.headline); Text(project.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); projectMenu(project) }
                }
            } else if !model.projects.isEmpty {
                Section {
                    let projects = showProjects ? model.projects : Array(model.projects.prefix(5))
                    ForEach(projects) { project in
                        HStack {
                            Button { model.selectProject(project) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(project.name).lineLimit(1)
                                    Spacer()
                                    Text(String(project.count ?? 0)).font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 3).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            projectMenu(project)
                        }
                    }
                    if model.projects.count > 5 {
                        Button(showProjects ? "收起项目" : "查看全部 \(model.projects.count) 个项目") { showProjects.toggle() }.font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("项目") }
            }
            Section {
                if !model.error.isEmpty { NativeNotice(text: model.error, isError: true).listRowSeparator(.hidden) }
                if model.sessions.isEmpty && !model.loading { Text("没有匹配的对话").foregroundStyle(.secondary).padding(.vertical, 16) }
                ForEach(model.sessions, id: \.identity) { row in
                    HStack(spacing: 12) {
                        if selecting {
                            Button { if !selected.insert(row.identity).inserted { selected.remove(row.identity) } } label: { Image(systemName: selected.contains(row.identity) ? "checkmark.circle.fill" : "circle").font(.title3) }.buttonStyle(.plain)
                        }
                        Button { if selecting { if !selected.insert(row.identity).inserted { selected.remove(row.identity) } } else { onSelect(row) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    if row.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                                    Text(row.title).font(.system(size: 16, weight: model.selected?.identity == row.identity ? .semibold : .regular)).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if row.readOnly == true { Image(systemName: "doc.text").font(.caption).foregroundStyle(.tertiary).accessibilityLabel("只读历史") }
                                }
                                HStack(spacing: 5) {
                                    Text(row.projectName ?? row.hostLabel ?? "此电脑").lineLimit(1)
                                    if let recency = row.recency { Text("·"); Text(Date(timeIntervalSince1970: recency / 1000), style: .relative).lineLimit(1) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("native.session.\(row.id)")
                    }
                    .listRowBackground(model.selected?.identity == row.identity ? Color.linkSurface : Color.clear)
                    .contextMenu { sessionActions(row) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { perform { try await model.preferences([row], changes: ["hidden": .bool(!(row.hidden ?? false))]) } } label: { Label(row.hidden == true ? "恢复" : "隐藏", systemImage: row.hidden == true ? "eye" : "eye.slash") }.tint(.gray)
                        if row.readOnly != true && row.host == "local" { Button { archive = row } label: { Label(row.archived == true ? "取消归档" : "归档", systemImage: "archivebox") }.tint(.secondary) }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { perform { try await model.preferences([row], changes: ["pinned": .bool(!(row.pinned ?? false))]) } } label: { Label(row.pinned == true ? "取消置顶" : "置顶", systemImage: "pin") }.tint(.gray)
                    }
                }
                if model.hasMore { Button { Task { await model.load(more: true) } } label: { HStack { Text("加载更多对话"); Spacer(); if model.loading { ProgressView() } } }.disabled(model.loading) }
            } header: { HStack { Text(model.project == nil ? "最近对话" : "项目对话"); Spacer(); Text("\(model.sessions.count) / \(model.total)") } }
            if !model.warnings.isEmpty { Section { Text(model.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) } }
            Section { Button(action: onSettings) { Label("设置", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("native.library.settings") }
        }
    }
    @ToolbarContentBuilder private var filterControls: some ToolbarContent {
            ToolbarItem(placement: .navigationBarTrailing) { Menu {
                Toggle("归档对话", isOn: $model.archived); Toggle("已隐藏", isOn: $model.hidden)
                Toggle("仅桌面来源", isOn: $model.desktopOnly); Toggle("内部会话", isOn: $model.includeInternal)
                Picker("排序", selection: $model.sort) { Text("最近更新").tag("updated"); Text("标题").tag("title") }
                Button(selecting ? "结束多选" : "选择对话") { selecting.toggle(); selected.removeAll() }
            } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }.accessibilityLabel("筛选与排序") }
    }
    @ViewBuilder private var batchControls: some View {
            if selecting {
                HStack { Text("已选 \(selected.count)").font(.caption); Spacer(); Button("全选") { selected = Set(model.sessions.map(\.identity)) }; Button(model.hidden ? "恢复" : "隐藏") { batchConfirm = true }.disabled(selected.isEmpty); Button("完成") { selecting = false; selected = [] } }.padding(16).background(.regularMaterial)
            }
    }
    @ViewBuilder private func sessionActions(_ row: LinkSession) -> some View {
        Button(row.pinned == true ? "取消置顶" : "置顶", systemImage: "pin") { perform { try await model.preferences([row], changes: ["pinned": .bool(!(row.pinned ?? false))]) } }
        if row.readOnly != true {
            Button("重命名", systemImage: "pencil") { name = row.title; rename = row }
            if row.host == "local" { Button(row.archived == true ? "取消归档" : "归档", systemImage: "archivebox") { archive = row } }
        }
        Button(row.hidden == true ? "恢复显示" : "从列表隐藏", systemImage: "eye.slash") { perform { try await model.preferences([row], changes: ["hidden": .bool(!(row.hidden ?? false))]) } }
    }
    private func projectMenu(_ project: LinkProject) -> some View {
        Menu {
            Button("在项目中新建对话", systemImage: "square.and.pencil") { model.selectProject(project); onNewChat() }
            if project.registered == true {
                Button("修改名称", systemImage: "pencil") { renameProject = project }
                Button(project.hidden == true ? "恢复项目" : "隐藏项目", systemImage: "eye.slash") { perform { try await model.updateProject(project, changes: ["hidden": .bool(!(project.hidden ?? false))]) } }
                if project.host == "local" {
                    Button("Codex 项目配置", systemImage: "slider.horizontal.3") { projectSettings = project }
                    Button("查看 AGENTS.md", systemImage: "doc.text") { perform { let result = try await model.api.value("/api/workspace/agents", query: ["project": project.key]); agents = result["text"].string; showAgents = true } }
                }
            } else { Button("添加此项目", systemImage: "folder.badge.plus") { renameProject = project } }
            Button("复制目录", systemImage: "doc.on.doc") { UIPasteboard.general.string = project.cwd }
        } label: { Image(systemName: "ellipsis").frame(width: 38, height: 38).contentShape(Rectangle()) }.accessibilityLabel(project.name + "的操作")
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { self.error = error.localizedDescription } } }
}

struct NativeSessionRename: View {
    @ObservedObject var model: WorkspaceModel
    let row: LinkSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("对话名称", text: $title)
                NativeNotice(text: error, isError: true)
            }.navigationTitle("重命名对话").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task {
                            busy = true; defer { busy = false }
                            do { try await model.rename(row, name: title); dismiss() }
                            catch { self.error = error.localizedDescription }
                        } }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.onAppear { title = row.title }.interactiveDismissDisabled(busy)
        }
    }
}

struct NativeProjectForm: View {
    @ObservedObject var model: WorkspaceModel
    let initial: LinkProject?
    var onSaved: ((LinkProject) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var createDirectory = false
    @State private var browse = false
    @State private var busy = false
    @State private var error = ""
    @State private var attempt: (content: String, id: String)?
    private var editing: Bool { initial?.registered == true }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("项目名称", text: $name).accessibilityIdentifier("native.project.name") }
                Section("Mac 目录") {
                    TextField("/Users/you/Projects/my-project", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(editing).accessibilityIdentifier("native.project.path")
                    if !editing { Button("浏览 Mac 文件夹", systemImage: "folder") { browse = true }; Toggle("目录不存在时创建新文件夹", isOn: $createDirectory) }
                }
                Section { NativeNotice(text: error, isError: true); Text("项目登记保存在 codex-link；隐藏项目不会删除文件。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(editing ? "修改项目" : "新建项目").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button { Task { await save() } } label: { if busy { ProgressView() } else { Text("保存").bold() } }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || path.isEmpty).accessibilityIdentifier("native.project.save") }
            }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $browse) { NativeDirectoryPicker(api: model.api, initial: path) { path = $0; if name.isEmpty { name = URL(fileURLWithPath: $0).lastPathComponent } } }
            .onAppear { name = initial?.name ?? ""; path = initial?.cwd ?? "" }
        }
    }
    private func save() async {
        busy = true; error = ""; defer { busy = false }
        do {
            let body: JSONValue
            if editing { body = json(["action": string("update"), "key": string(initial!.key), "changes": json(["name": string(name)])]) }
            else {
                let content = name + "\n" + path + "\n" + String(createDirectory)
                if attempt?.content != content { attempt = (content, UUID().uuidString.lowercased()) }
                body = json(["action": string("create"), "id": string(attempt!.id), "name": string(name), "cwd": string(path), "createDirectory": .bool(createDirectory)])
            }
            let result = try await model.api.value("/api/workspace/projects", body: body)
            let project = try JSONDecoder().decode(LinkProject.self, from: JSONEncoder().encode(result["project"]))
            await model.load(); onSaved?(project); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeDirectoryPicker: View {
    let api: NativeAPI
    let initial: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var filter = ""
    @State private var result: JSONValue = .null
    @State private var folders: [JSONValue] = []
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Mac 上的目录") {
                    TextField("目录路径", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { load(path) }
                    TextField("筛选子目录", text: $filter)
                    Button("前往 / 筛选") { load(path) }
                }
                if !result["parent"].string.isEmpty { Button("上一级", systemImage: "arrow.up") { load(result["parent"].string) } }
                ForEach(folders, id: \.self) { row in Button { load(row["path"].string) } label: { Label(row["name"].string, systemImage: "folder") } }
                if result["hasMore"].bool { Button("更多文件夹") { load(result["path"].string, more: true) } }
                if busy { ProgressView() }
                NativeNotice(text: error, isError: true)
            }
            .navigationTitle("选择 Mac 文件夹").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("选择") { onSelect(result["path"].string); dismiss() }.disabled(result["path"].string.isEmpty || busy) } }
            .task { path = initial; await read(initial) }.disabled(busy)
        }
    }
    private func load(_ path: String, more: Bool = false) { Task { await read(path, more: more) } }
    private func read(_ target: String, more: Bool = false) async {
        busy = true; error = ""; defer { busy = false }
        do {
            result = try await api.value("/api/workspace/directories", query: ["path": target, "q": filter, "offset": String(more ? folders.count : 0)])
            path = result["path"].string; folders = (more ? folders : []) + result["directories"].array
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeNewChat: View {
    @ObservedObject var model: WorkspaceModel
    var initialPrompt = ""
    let onCreated: (LinkSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [LinkProject] = []
    @State private var project = ""
    @State private var title = ""
    @State private var newProject = false
    @State private var busy = false
    @State private var error = ""
    @State private var attempt: (content: String, id: String)?
    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    Picker("工作目录", selection: $project) { Text("选择项目").tag(""); ForEach(projects) { Text($0.name).tag($0.key) } }
                    if let chosen = projects.first(where: { $0.key == project }) { Text(chosen.cwd).font(.caption).foregroundStyle(.secondary) }
                    Button("新建项目", systemImage: "folder.badge.plus") { newProject = true }
                }
                if initialPrompt.isEmpty {
                    Section("对话标题") { TextField("新对话", text: $title).accessibilityIdentifier("native.chat.title") }
                } else {
                    Section("新任务") { Text(initialPrompt).textSelection(.enabled).accessibilityIdentifier("native.chat.initialPrompt") }
                }
                NativeNotice(text: error, isError: true)
            }
            .navigationTitle("新建对话").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }; ToolbarItem(placement: .confirmationAction) { Button { Task { await create() } } label: { if busy { ProgressView() } else { Text(initialPrompt.isEmpty ? "创建" : "开始任务").bold() } }.disabled(busy || project.isEmpty).accessibilityIdentifier("native.chat.create") } }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $newProject) { NativeProjectForm(model: model, initial: model.project?.registered == false ? model.project : nil) { p in projects.removeAll { $0.key == p.key }; projects.append(p); project = p.key } }
            .task {
                if !initialPrompt.isEmpty && title.isEmpty { title = String(initialPrompt.split(separator: "\n", maxSplits: 1).first.map(String.init)?.prefix(90) ?? "新任务") }
                do {
                    let value = try await model.api.value("/api/projects")
                    projects = try JSONDecoder().decode([LinkProject].self, from: JSONEncoder().encode(value["projects"]))
                    project = model.project.flatMap { p in projects.contains(where: { $0.key == p.key }) ? p.key : nil } ?? projects.first?.key ?? ""
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func create() async {
        busy = true; error = ""; defer { busy = false }
        do {
            let content = project + "\n" + title
            if attempt?.content != content { attempt = (content, UUID().uuidString.lowercased()) }
            let result = try await model.api.value("/api/sessions", body: json(["project": string(project), "title": string(title.isEmpty ? "新对话" : title), "id": string(attempt!.id)]))
            let row: LinkSession = try await model.api.request("/api/session-meta/\(result["id"].string)", query: ["host": result["host"].string.isEmpty ? "local" : result["host"].string])
            await model.load(); onCreated(row); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
