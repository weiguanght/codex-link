import SwiftUI
import UniformTypeIdentifiers

struct NativeChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var workspace: WorkspaceModel
    let onSidebar: () -> Void
    let onNewChat: (String) -> Void
    let onSettings: () -> Void
    var showSidebar = true
    @State private var threadSettings = false
    @State private var status = false
    @State private var importFile = false
    @State private var uploading = false
    @State private var actionError = ""
    @State private var share: ShareFile?
    @State private var messageAction: NativeRow?
    @State private var following = true
    @State private var homeMode = 0
    @State private var taskPrompt = ""
    @State private var projectSort = "tasks"
    @State private var hostFilter = "all"
    @FocusState private var focused: Bool
    private struct Block: Identifiable {
        let rows: [NativeRow]
        var id: String { rows[0].key }
        var process: Bool { rows[0].isProcess }
    }
    private var blocks: [Block] {
        var result: [Block] = [], process: [NativeRow] = []
        for row in chat.visibleRows {
            if row.isProcess { process.append(row) }
            else { if !process.isEmpty { result.append(Block(rows: process)); process = [] }; result.append(Block(rows: [row])) }
        }
        if !process.isEmpty { result.append(Block(rows: process)) }; return result
    }
    var body: some View {
        Group {
            if chat.session == nil { home }
            else { conversation }
        }
        .background(Color.linkCanvas)
        .toolbar { navigationControls }
        .sheet(isPresented: $threadSettings) { NativeThreadSettings(chat: chat) }
        .sheet(isPresented: $status) { threadStatus }
        .sheet(item: $share) { ShareView(file: $0.url) }
        .sheet(item: $messageAction) { NativeMessageAction(chat: chat, row: $0, workspace: workspace) }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): uploading = true; Task { defer { uploading = false }; do { for url in urls { try await chat.upload(url) } } catch { actionError = error.localizedDescription } }
            case .failure(let error): actionError = error.localizedDescription
            }
        }
        .alert("操作失败", isPresented: Binding(get: { !actionError.isEmpty }, set: { if !$0 { actionError = "" } })) { Button("好", role: .cancel) {} } message: { Text(actionError) }
        .onChange(of: chat.session?.identity) { _ in following = true; focused = false }
        .environment(\.openURL, OpenURLAction { url in
            if let file = chat.files.first(where: { $0["reference"].string == url.absoluteString || $0["reference"].string == url.path }) {
                download(file); return .handled
            }
            return ["https", "http"].contains(url.scheme ?? "") ? .systemAction : .discarded
        })
    }
    @ToolbarContentBuilder private var navigationControls: some ToolbarContent {
            ToolbarItem(placement: .navigationBarLeading) {
                if showSidebar { NativeIconButton(symbol: "sidebar.left", label: "项目与对话", action: onSidebar).accessibilityIdentifier("native.sidebar") }
            }
            ToolbarItem(placement: .principal) {
                Button { if chat.session != nil { status = true } else { onSettings() } } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Text(chat.session == nil ? "Codex" : chat.meta["title"].string.isEmpty ? chat.session!.title : chat.meta["title"].string).font(.system(size: 16, weight: .semibold)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                        Text(chat.session?.projectName ?? "在 Mac 上接着做").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: 240)
                }.buttonStyle(.plain).accessibilityLabel("会话状态与详情")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NativeIconButton(symbol: "square.and.pencil", label: "新建对话", action: { onNewChat("") })
            }
    }
    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("你的工作空间", systemImage: "laptopcomputer").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(); Button(action: onSettings) { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("设置").accessibilityIdentifier("native.home.settings")
                }
                Text("接着推进你的工作").font(.system(size: 28, weight: .semibold)).padding(.top, 6)
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    TextField("开始一个新任务…", text: $taskPrompt, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("native.home.prompt")
                    Button { onNewChat(taskPrompt); taskPrompt = "" } label: {
                        Image(systemName: "arrow.up").font(.subheadline.weight(.semibold)).frame(width: 38, height: 38).foregroundStyle(Color.linkCanvas).background(Color.primary, in: Circle())
                    }.disabled(taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("开始任务").accessibilityIdentifier("native.home.create")
                }.padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 9).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 26))
                HStack(spacing: 8) {
                    Picker("显示方式", selection: $homeMode) { Text("最近任务").tag(0); Text("项目").tag(1) }.pickerStyle(.segmented)
                    Menu {
                        Button("全部 Mac 与主机") { hostFilter = "all" }
                        ForEach(Array(Set(workspace.sessions.map(\.host))).sorted(), id: \.self) { host in
                            Button(workspace.sessions.first(where: { $0.host == host })?.hostLabel ?? host) { hostFilter = host }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 40, height: 40) }.accessibilityLabel("筛选主机")
                }.padding(.vertical, 6)
                if !workspace.error.isEmpty { NativeNotice(text: workspace.error, isError: true) }
                if let project = workspace.project {
                    HStack { Label(project.name, systemImage: "folder").font(.subheadline.weight(.medium)); Spacer(); Button("全部项目") { workspace.selectProject(nil) }.font(.caption) }
                }
                if homeMode == 1 && workspace.project == nil {
                    Menu {
                        Button("按任务数量") { projectSort = "tasks" }
                        Button("按项目名称") { projectSort = "name" }
                    } label: { Label("项目排序", systemImage: "arrow.up.arrow.down").font(.caption) }
                    ForEach(homeProjects) { project in
                        Button { workspace.selectProject(project); homeMode = 0 } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "folder").font(.title3).frame(width: 44, height: 44).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 5) { Text(project.name).font(.body.weight(.medium)); Text(project.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); Text(String(project.count ?? 0)).font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(workspace.sessions.filter { hostFilter == "all" || $0.host == hostFilter }, id: \.identity) { row in
                        Button { chat.logView = false; workspace.selected = row } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.readOnly == true ? "doc.text" : "terminal").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(row.title).font(.body.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: 6) { Text(row.projectName ?? "此电脑").lineLimit(1); if row.readOnly == true { Text("· 只读历史") }; if row.pinned == true { Image(systemName: "pin.fill") } }.font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 5)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("native.home.session.\(row.id)")
                        Divider().opacity(0.5)
                    }
                    if workspace.hasMore { Button("加载更多任务") { Task { await workspace.load(more: true) } }.frame(maxWidth: .infinity).padding().disabled(workspace.loading) }
                }
                if workspace.loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if workspace.sessions.isEmpty && !workspace.loading { Text("在一个项目中新建对话，开始你的第一个任务。").foregroundStyle(.secondary).padding(.vertical, 25) }
            }.padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.refreshable { await workspace.load() }.accessibilityIdentifier("native.home")
    }
    private var homeProjects: [LinkProject] {
        workspace.projects.filter { hostFilter == "all" || $0.host == hostFilter }.sorted { left, right in
            if projectSort == "name" { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            if left.count != right.count { return (left.count ?? 0) > (right.count ?? 0) }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.hasMore {
                            Button { let anchor = chat.rows.first?.key; Task { following = false; await chat.older(); if let anchor { proxy.scrollTo(anchor, anchor: .top) } } } label: { if chat.loadingOlder { ProgressView() } else { Label("更早的消息", systemImage: "arrow.up") } }.font(.caption).frame(maxWidth: .infinity).disabled(chat.loadingOlder)
                        }
                        if chat.loading { ProgressView("正在读取对话…").frame(maxWidth: .infinity).padding(.vertical, 24) }
                        ForEach(blocks) { block in
                            if block.process {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 20) { ForEach(block.rows) { row in processRow(row).id(row.key) } }.padding(.top, 12)
                                } label: { Label("执行过程 · \(block.rows.count) 项", systemImage: "terminal").font(.subheadline).foregroundStyle(.secondary) }
                                .padding(14).background(Color.linkSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 18)).id(block.id)
                            } else { message(block.rows[0]).id(block.id) }
                        }
                        if chat.running { HStack(spacing: 10) { ProgressView().scaleEffect(0.7); Text("Codex 正在执行").font(.caption).foregroundStyle(.secondary) } }
                        ForEach(Array(chat.requests.enumerated()), id: \.offset) { _, request in NativeApprovalView(chat: chat, request: request) }
                        if !chat.files.isEmpty {
                            DisclosureGroup("对话文件 · \(chat.files.count)") { ForEach(Array(chat.files.enumerated()), id: \.offset) { _, file in Button { download(file) } label: { Label(file["name"].string, systemImage: file["image"].bool ? "photo" : "doc") }.padding(.vertical, 6) } }.font(.subheadline)
                        }
                        NativeNotice(text: chat.pollingError, isError: true)
                        NativeNotice(text: chat.error, isError: true)
                        NativeNotice(text: chat.notice)
                        Color.clear.frame(height: 1).id("native-bottom").background(GeometryReader { geometry in Color.clear.preference(key: BottomPosition.self, value: geometry.frame(in: .named("native-transcript")).maxY) })
                    }.padding(.horizontal, 22).padding(.vertical, 24).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "native-transcript")
                .onPreferenceChange(BottomPosition.self) { bottom in following = bottom < viewport.size.height + 75 }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.revision) { _ in if following && !chat.loadingOlder { proxy.scrollTo("native-bottom", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !following { NativeIconButton(symbol: "arrow.down", label: "回到最新消息", filled: true) { following = true; withAnimation { proxy.scrollTo("native-bottom", anchor: .bottom) } }.padding(16) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
    }
    private func processRow(_ row: NativeRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title ?? row.kind ?? "执行过程").font(.caption.weight(.semibold))
            Text(chat.rowText(row)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if chat.rowHasMore(row) { Button("展开完整内容") { perform { try await chat.expand(row) } }.font(.caption) }
        }
    }
    private func message(_ row: NativeRow) -> some View {
        VStack(alignment: row.role == "user" ? .trailing : .leading, spacing: 10) {
            if row.role == "user" {
                Text(chat.rowText(row)).font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 14).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 24)).padding(.leading, 30)
            } else if row.role == "error" { NativeNotice(text: chat.rowText(row), isError: true) }
            else { NativeMarkdown(text: chat.rowText(row)).font(.system(size: 16)).lineSpacing(5) }
            if let attachments = row.attachments {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in Label(a["name"].string.isEmpty ? "附件" : a["name"].string, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
            }
            if chat.rowHasMore(row) { Button("继续加载正文") { following = false; perform { try await chat.expand(row) } }.font(.caption) }
            if row.role == "assistant" {
                HStack(spacing: 20) {
                    Button { UIPasteboard.general.string = chat.rowText(row) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制回复")
                    ShareLink(item: chat.rowText(row)) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享回复")
                    if row.forkable == true && !chat.readOnly { Button { messageAction = row } label: { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("从此处分支") }
                }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.role == "user" ? .trailing : .leading)
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = chat.rowText(row) }
            if row.editable == true && !chat.readOnly { Button("编辑消息", systemImage: "pencil") { messageAction = row } }
            if row.forkable == true && !chat.readOnly { Button("从此处分支", systemImage: "arrow.triangle.branch") { messageAction = row } }
        }
    }
    private var composer: some View {
        VStack(spacing: 9) {
            if chat.readOnly {
                HStack(spacing: 10) { Image(systemName: "doc.text"); Text("只读历史").font(.subheadline); Spacer(); if chat.logView && chat.session?.readOnly != true { Button("返回交互视图") { chat.logView = false } } }.foregroundStyle(.secondary).padding(18)
            } else {
                if !chat.connected {
                    HStack { Text(chat.meta["connecting"].bool || chat.meta["activating"].bool ? "正在连接 Mac 会话…" : "会话尚未连接").font(.caption).foregroundStyle(.secondary); Spacer(); Button("连接会话") { perform { try await chat.reconnect() } }.font(.caption.weight(.medium)) }.padding(.horizontal, 9)
                }
                if !chat.draft.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack {
                        ForEach(chat.draft.attachments) { file in HStack(spacing: 8) { Image(systemName: "doc"); Text(file.name).lineLimit(1); Button { chat.draft.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") } }.font(.caption).padding(10).background(Color.linkSurface, in: Capsule()) }
                    } }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    NativeIconButton(symbol: "plus", label: "添加附件") { importFile = true }.disabled(uploading || chat.busy)
                    TextField("继续这个任务…", text: $chat.draft.text, axis: .vertical).lineLimit(1...7).font(.system(size: 16)).focused($focused).padding(.vertical, 12).accessibilityIdentifier("native.composer")
                    if uploading || chat.busy { ProgressView().frame(width: 44, height: 44) }
                    else if chat.running && chat.draft.text.isEmpty && chat.draft.attachments.isEmpty {
                        NativeIconButton(symbol: "stop.fill", label: "停止任务", filled: true) { perform { try await chat.stop() } }.disabled(!chat.connected)
                    } else {
                        NativeIconButton(symbol: "arrow.up", label: "发送消息", filled: true) { following = true; Task { await chat.send() } }.disabled(!chat.canSend).opacity(chat.canSend ? 1 : 0.3).accessibilityIdentifier("native.send")
                    }
                }.padding(7).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 29))
                HStack {
                    Button { threadSettings = true } label: { HStack(spacing: 5) { Text(chat.meta["model"].string.isEmpty ? "模型" : chat.meta["model"].string).lineLimit(1); if !chat.meta["effort"].string.isEmpty { Text("· " + chat.meta["effort"].string) }; Image(systemName: "chevron.down").font(.system(size: 8)) } }.disabled(!chat.connected)
                    Spacer()
                    Menu {
                        Picker("工作模式", selection: $chat.draft.workMode) { Text("普通").tag("default"); Text("计划").tag("plan") }
                        Picker("发送方式", selection: $chat.draft.sendMode) { Text("发送新消息").tag("send"); Text("完成后发送").tag("queue"); Text("补充当前任务").tag("steer") }
                    } label: { HStack(spacing: 4) { Text(chat.draft.workMode == "plan" ? "计划" : chat.draft.sendMode == "queue" ? "排队发送" : chat.draft.sendMode == "steer" ? "补充任务" : "普通模式"); Image(systemName: "slider.horizontal.3") } }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8).background(.regularMaterial)
    }
    private var threadStatus: some View {
        NavigationStack {
            Form {
                Section {
                    Text(chat.meta["title"].string.isEmpty ? chat.session?.title ?? "Codex" : chat.meta["title"].string).font(.headline)
                    Label(chat.readOnly ? "只读历史" : chat.connected ? chat.running ? "执行中" : "已连接" : "等待连接", systemImage: chat.readOnly ? "doc.text" : chat.running ? "circle.dotted" : "laptopcomputer")
                    if let row = chat.session { Text(row.cwd ?? "").font(.caption).textSelection(.enabled); Text(row.hostLabel ?? row.host).font(.caption).foregroundStyle(.secondary) }
                }
                if chat.session != nil {
                    Section("操作") {
                        if !chat.readOnly { Button("模型与推理设置") { status = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { threadSettings = true } }; Button("重新连接") { perform { try await chat.reconnect() } } }
                        if chat.capabilities["fullLog"].bool && !chat.logView { Button("只读查看完整日志") { chat.logView = true; status = false } }
                        if let row = chat.session { Button("复制会话 ID") { UIPasteboard.general.string = row.id }; Button("返回任务列表") { workspace.selected = nil; status = false } }
                    }
                    if !chat.meta["submissions"].array.isEmpty {
                        Section("发送队列") {
                            ForEach(Array(chat.meta["submissions"].array.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item["text"].string).lineLimit(3)
                                    Text(item["status"].string).font(.caption).foregroundStyle(.secondary)
                                    if item["status"].string == "queued" {
                                        Button("取消排队") { perform { _ = try await chat.action("queue", body: json(["id": item["id"]])) } }
                                    }
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("会话详情").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { status = false } } }
        }
    }
    private func download(_ file: JSONValue) {
        guard let row = chat.session else { return }
        perform { let url = try await chat.api.download("/api/sessions/\(row.id)/files/\(file["id"].string)", query: ["host": row.host], name: file["name"].string); share = ShareFile(url: url) }
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription } } }
}
private struct BottomPosition: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }

struct NativeThreadSettings: View {
    @ObservedObject var chat: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: JSONValue = .null
    @State private var model = ""
    @State private var effort = ""
    @State private var fast = false
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("当前会话") {
                    TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !catalog["models"].array.isEmpty { Picker("可用模型", selection: $model) { ForEach(Array(catalog["models"].array.enumerated()), id: \.offset) { _, row in Text(row["name"].string.isEmpty ? row["id"].string : row["name"].string).tag(row["id"].string) } } }
                    TextField("推理强度", text: $effort).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if catalog["fastMode"]["allowed"].bool { Toggle("Fast 模式", isOn: $fast) }
                }
                if !catalog["skills"].array.isEmpty {
                    Section("随消息使用的 Skills（最多 8 个）") {
                        ForEach(Array(catalog["skills"].array.enumerated()), id: \.offset) { _, row in
                            Toggle(row["name"].string, isOn: Binding(get: { chat.draft.skills.contains(row["id"].string) }, set: { enabled in if enabled && chat.draft.skills.count < 8 { chat.draft.skills.append(row["id"].string) } else { chat.draft.skills.removeAll { $0 == row["id"].string } } }))
                        }
                    }
                }
                NativeNotice(text: error, isError: true)
            }
            .navigationTitle("模型与推理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }; ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(busy || model.isEmpty || !chat.connected) } }
            .task {
                model = chat.meta["model"].string; effort = chat.meta["effort"].string; fast = chat.meta["serviceTier"].string == "fast"
                do { if let row = chat.session { catalog = try await chat.api.value("/api/sessions/\(row.id)/catalog", query: ["host": row.host]) } } catch { self.error = error.localizedDescription }
            }.interactiveDismissDisabled(busy)
        }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do { var fields = ["model": string(model), "effort": string(effort)]; if catalog["fastMode"]["allowed"].bool { fields["fastMode"] = .bool(fast) }; _ = try await chat.action("settings", body: json(fields)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct NativeMessageAction: View {
    @ObservedObject var chat: ChatModel
    let row: NativeRow
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fork = false
    @State private var busy = false
    @State private var error = ""
    @State private var attempt: (payload: JSONValue, id: String)?
    var body: some View {
        NavigationStack {
            Form {
                if row.editable == true { Section("消息内容") { TextEditor(text: $text).frame(minHeight: 200); Toggle("在新分支中继续", isOn: $fork) } }
                Section { Text(row.editable == true ? "编辑会回退并重新发送该位置之后的任务；可以选择保留原对话，创建新分支。" : "创建此消息位置的分支，原对话会保留。").font(.footnote).foregroundStyle(.secondary); NativeNotice(text: error, isError: true) }
            }.navigationTitle(row.editable == true ? "编辑消息" : "创建分支").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }; ToolbarItem(placement: .confirmationAction) { Button("确认") { Task { await submit() } }.disabled(busy || (row.editable == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) } }
                .onAppear { text = chat.rowText(row) }.interactiveDismissDisabled(busy)
        }
    }
    private func submit() async {
        busy = true; error = ""; defer { busy = false }
        do {
            var fields = ["action": string(row.editable == true ? fork ? "edit-fork" : "edit" : "fork"), "key": string(chatCursor), "version": row.version, "text": string(text)]
            let payload = json(fields)
            if attempt?.payload != payload { attempt = (payload, UUID().uuidString.lowercased()) }
            fields["id"] = string(attempt!.id)
            let result = try await chat.action("message-action", body: json(fields))
            if result["status"].string == "unknown" { error = "结果未确认，请刷新检查，不要重复创建。"; return }
            await workspace.load()
            if let target = workspace.sessions.first(where: { $0.id == result["id"].string && $0.host == result["host"].string }) {
                if !result["draft"].string.isEmpty { chat.preserveDraft(result["draft"].string, for: target) }
                workspace.selected = target
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private var chatCursor: String { chat.cursor(for: row) }
}
