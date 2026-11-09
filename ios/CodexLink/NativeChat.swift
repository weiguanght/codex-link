import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

struct NativeChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var workspace: WorkspaceModel
    let onSidebar: () -> Void
    let onHome: () -> Void
    let onNewChat: (String) -> Void
    let onSettings: () -> Void
    var showSidebar = true
    @State private var threadSettings = false
    @State private var permissionSettings = false
    @State private var sendSettings = false
    @State private var chooseSendMode = false
    @State private var contextUsage: JSONValue = .null
    @AppStorage("native.followUpBehavior") private var defaultSendMode = "send"
    @State private var status = false
    @State private var importFile = false
    @State private var takePhoto = false
    @State private var photoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var actionError = ""
    @State private var sessionUsage: JSONValue = .null
    @State private var usageLoading = false
    @State private var share: ShareFile?
    @State private var preview: NativePreviewFile?
    @State private var downloading = Set<String>()
    @State private var messageAction: NativeRow?
    @State private var toolDetail: NativeRow?
    @State private var workspaceSession: LinkSession?
    @State private var following = true
    @State private var draggingHistory = false
    @State private var bottomPosition: CGFloat?
    @State private var scrollRequest = 0
    @State private var historyLoadRequest = 0
    @State private var composerHeight: CGFloat = 110
    @StateObject private var historyScroll = NativeHistoryScrollController()
    @State private var backProgress: CGFloat = 0
    @State private var completingBack = false
    @State private var homeMode = 0
    @State private var taskPrompt = ""
    @State private var projectSort = "tasks"
    @State private var hostFilter = "all"
    @FocusState private var focused: Bool
    private struct Block: Identifiable {
        let rows: [NativeRow]
        var id: String { rows.first?.key ?? "" }
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
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                home
                    .overlay { if chat.session != nil { Color.black.opacity(0.35 * (1 - backProgress)).allowsHitTesting(false) } }
                    .offset(x: chat.session == nil ? 0 : -geometry.size.width * 0.30 * (1 - backProgress))
                    .allowsHitTesting(chat.session == nil)
                    .accessibilityHidden(chat.session != nil)
                if chat.session != nil {
                    conversation
                        .background(Color.linkCanvas)
                        .offset(x: geometry.size.width * backProgress)
                        .shadow(color: .black.opacity(0.12 * backProgress), radius: 8, x: -3)
                        .background(NativeBackPanObserver(enabled: showSidebar && !completingBack,
                            onChange: { distance in
                                backProgress = min(1, max(0, distance / max(1, geometry.size.width)))
                            }, onEnd: { distance, velocity, cancelled in
                                let progress = min(1, max(0, distance / max(1, geometry.size.width)))
                                if !cancelled && NativeBackNavigation.shouldFinish(progress: progress, velocity: velocity) {
                                    completeBack()
                                } else {
                                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) { backProgress = 0 }
                                }
                            }))
                }
            }.clipped()
        }
        .task(id: completingBack) {
            guard completingBack else { return }
            let identity = chat.session?.identity
            do { try await Task.sleep(nanoseconds: 260_000_000) } catch { return }
            guard chat.session?.identity == identity else { return }
            onHome()
        }
        .background(Color.linkCanvas)
        .toolbar { navigationControls }
        .sheet(isPresented: $threadSettings) { NativeThreadSettings(chat: chat) }
        .sheet(isPresented: $permissionSettings) { NavigationStack { NativeCodexSettings(api: chat.api, workspace: workspace, initialScope: "", permissionsOnly: true) } }
        .sheet(isPresented: $sendSettings) { messageSendSettings }
        .sheet(isPresented: $chooseSendMode) { sendModeChooser }
        .task(id: chat.session?.identity) {
            contextUsage = .null
            guard let session = chat.session else { return }
            while !Task.isCancelled {
                do {
                    let result = try await chat.api.value("/api/native/v1/threads/\(session.id)/usage", query: ["host": session.host])
                    guard !Task.isCancelled, chat.session?.identity == session.identity else { return }
                    contextUsage = result["context"]
                } catch is CancellationError { return }
                catch { /* Missing log or network: retain the last confirmed sample. */ }
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        .sheet(isPresented: $status) { threadStatus }
        .sheet(item: $share) { ShareView(file: $0.url) }
        .sheet(item: $preview, onDismiss: { preview = nil }) { NativeFilePreview(file: $0) }
        .sheet(item: $toolDetail) { row in NativeToolDetail(chat: chat, rowKey: row.key, sessionIdentity: chat.session?.identity ?? "") }
        .sheet(item: $messageAction) { NativeMessageAction(chat: chat, row: $0, workspace: workspace) }
        .sheet(item: $workspaceSession) { session in
            NativeWorkspaceBrowser(api: chat.api, session: session, canEdit: chat.capabilities["workspaceWrite"].bool) { text in
                if chat.appendWorkspaceContext(text, for: session) { focused = true }
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): uploading = true; Task { defer { uploading = false }; do { for url in urls { try await chat.upload(url) } } catch { actionError = error.localizedDescription } }
            case .failure(let error): actionError = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task {
                defer { selectedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                          let jpeg = image.jpegData(compressionQuality: 0.9) else { throw LinkError.message("无法读取所选图片") }
                    try await uploadImage(jpeg, name: "图片-\(UUID().uuidString.prefix(8)).jpg")
                } catch { actionError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $takePhoto) {
            NativeCameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.9) else { actionError = "无法处理拍摄的照片。"; return }
                Task { do { try await uploadImage(data, name: "拍摄-\(UUID().uuidString.prefix(8)).jpg") } catch { actionError = error.localizedDescription } }
            }.ignoresSafeArea()
        }
        .alert("操作失败", isPresented: Binding(get: { !actionError.isEmpty }, set: { if !$0 { actionError = "" } })) { Button("好", role: .cancel) {} } message: { Text(actionError) }
        .onChange(of: chat.session?.identity) { _ in backProgress = 0; completingBack = false; chooseSendMode = false; historyLoadRequest = 0; historyScroll.releaseAnchor(); following = true; draggingHistory = false; bottomPosition = nil; focused = false; workspaceSession = nil; toolDetail = nil }
        .environment(\.openURL, OpenURLAction { url in
            if let file = NativeMessageLinks.file(for: url, files: chat.files) {
                download(file); return .handled
            }
            if NativeMessageLinks.reference(url) != nil {
                actionError = "此文件已不可用，或不在当前会话可下载的文件列表中。"
                return .handled
            }
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
    private func completeBack() {
        guard chat.session != nil, !completingBack else { return }
        completingBack = true
        focused = false
        withAnimation(.easeOut(duration: 0.25)) { backProgress = 1 }
    }
    @ToolbarContentBuilder private var navigationControls: some ToolbarContent {
            ToolbarItem(placement: .navigationBarLeading) {
                if chat.session != nil {
                    NativeIconButton(symbol: "chevron.left", label: "返回", action: {
                        completeBack()
                    }).accessibilityIdentifier("native.chat.back")
                } else if showSidebar {
                    NativeIconButton(symbol: "line.3.horizontal", label: "项目与对话", action: onSidebar).accessibilityIdentifier("native.sidebar")
                }
            }
            ToolbarItem(placement: .principal) {
                Button {
                    if let row = chat.session {
                        status = true
                        Task { await loadSessionUsage(row) }
                    } else {
                        onSettings()
                    }
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Text(chat.session == nil ? "Codex" : chat.meta["title"].string.isEmpty ? (chat.session?.title ?? "Codex") : chat.meta["title"].string).font(.system(size: 16, weight: .semibold)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                        Text(chat.session?.projectName ?? "在 Mac 上接着做").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: 240)
                }.buttonStyle(.plain).accessibilityLabel("会话状态与详情")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if chat.session == nil {
                    NativeIconButton(symbol: "gearshape", label: "设置", action: onSettings).accessibilityIdentifier("native.home.settings")
                } else {
                    Menu { chatDropdown } label: {
                        Image(systemName: "ellipsis").font(.system(size: 19, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("会话菜单")
                    .accessibilityIdentifier("native.chat.menu")
                }
            }
    }
    private func menuAction(_ title: String, icon: String, identifier: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NativeDropdownLabel(title: title, symbol: icon)
        }.buttonStyle(NativeDropdownButtonStyle()).disabled(!enabled).accessibilityIdentifier(identifier)
    }
    private var chatDropdown: some View {
        VStack(spacing: 0) {
            menuAction("工作区", icon: "folder", identifier: "native.workspace.open", enabled: chat.capabilities["workspaceRead"].bool) { workspaceSession = chat.session }
            Divider()
            menuAction("模型与推理", icon: "cpu", identifier: "native.thread.settings", enabled: chat.connected && !chat.readOnly) { threadSettings = true }
            Divider()
            menuAction("消息发送设置", icon: "slider.horizontal.3", identifier: "native.send.settings", enabled: !chat.readOnly) { sendSettings = true }
            Divider()
            menuAction("权限设置", icon: "checkmark.shield", identifier: "native.permission.settings", enabled: chat.connected) { permissionSettings = true }
            Divider()
            if let session = chat.session {
                NativeSessionMenu(model: workspace, row: session, expandedLabel: true)
                Divider()
            }
            menuAction("新建对话", icon: "square.and.pencil", identifier: "native.chat.new") { onNewChat("") }
        }.accessibilityElement(children: .contain)
    }
    private var messageSendSettings: some View {
        NavigationStack {
            Form {
                Picker("工作模式", selection: $chat.draft.workMode) { Text("普通").tag("default"); Text("计划").tag("plan") }
                Picker("默认发送方式", selection: $chat.draft.sendMode) {
                    Text("发送新消息").tag("send"); Text("完成后发送").tag("queue"); Text("补充当前任务").tag("steer")
                }.accessibilityIdentifier("native.send.defaultMode")
                Text("轻点发送按钮使用默认方式；长按可仅为本次消息选择方式。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("消息发送设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sendSettings = false } } }
                .onChange(of: chat.draft.sendMode) { defaultSendMode = $0 }
        }
    }
    private var sendModeChooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本次发送方式").font(.headline).padding(.horizontal, 20).padding(.vertical, 16)
            sendChoice("发送新消息", icon: "arrow.up.circle", mode: "send")
            sendChoice("完成后发送", icon: "clock.arrow.circlepath", mode: "queue")
            sendChoice("补充当前任务", icon: "arrow.turn.down.right", mode: "steer")
        }.padding(.bottom, 16).presentationDetents([.height(252)]).presentationDragIndicator(.visible)
    }
    private func sendChoice(_ title: String, icon: String, mode: String) -> some View {
        Button { chooseSendMode = false; sendMessage(mode: mode) } label: {
            HStack { Text(title); Spacer(); Image(systemName: icon) }.padding(.horizontal, 20).frame(height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!chat.canSend).accessibilityIdentifier("native.send.once." + mode)
    }
    private func sendMessage(mode: String? = nil) {
        historyScroll.releaseAnchor(); following = true
        Task { await chat.send(mode: mode) }
    }
    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("接着推进你的工作").font(.system(size: 28, weight: .semibold))
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
                        HStack(spacing: 4) {
                        Button { chat.logView = false; workspace.selected = row } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.readOnly == true ? "doc.text" : "terminal").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(row.title).font(.body.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: 6) { if row.unread == true { Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("未读") }; Text(row.projectName ?? "此电脑").lineLimit(1); if row.readOnly == true { Text("· 只读历史") }; if row.pinned == true { Image(systemName: "pin.fill") } }.font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("native.home.session.\(row.id)")
                        NativeSessionMenu(model: workspace, row: row)
                        }
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
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).background(NativeHistoryScrollProbe(
                            controller: historyScroll, identity: chat.session?.identity ?? "",
                            enabled: chat.hasMore && !chat.loadingOlder && !chat.loading,
                            keys: chat.visibleRows.map(\.key),
                            onLoad: { following = false; historyLoadRequest += 1 },
                            onDragging: { dragging in
                                draggingHistory = dragging
                                following = dragging || historyScroll.preservingHistory ? false : bottomPosition.map { $0 >= 0 && $0 <= viewport.size.height + 75 } ?? false
                            }
                        )).accessibilityHidden(true)
                        LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.loading { ProgressView("正在读取对话…").frame(maxWidth: .infinity).padding(.vertical, 24) }
                        ForEach(blocks) { block in
                            if block.process {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(block.rows) { row in
                                        processRow(row).id(row.key)
                                            .background(NativeHistoryRowMarker(id: row.key, controller: historyScroll))
                                            .modifier(NativeHistoryReveal(id: row.key, controller: historyScroll))
                                    }
                                }.id(block.id)
                            } else if let row = block.rows.first {
                                message(row).id(block.id).background(NativeHistoryRowMarker(id: block.id, controller: historyScroll))
                                    .modifier(NativeHistoryReveal(id: row.key, controller: historyScroll))
                            }
                        }
                        if chat.running { HStack(spacing: 10) { ProgressView().scaleEffect(0.7); Text("Codex 正在执行").font(.caption).foregroundStyle(.secondary) } }
                        ForEach(Array(chat.requests.enumerated()), id: \.offset) { _, request in NativeApprovalView(chat: chat, request: request) }
                        if !chat.files.isEmpty {
                            DisclosureGroup {
                                NativeFileListLayout {
                                    ForEach(Array(chat.files.enumerated()), id: \.offset) { _, file in
                                        Button { download(file) } label: {
                                            Label(file["name"].string, systemImage: file["image"].bool ? "photo" : "doc")
                                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                        }.disabled(downloading.contains("files/" + file["id"].string)).padding(.vertical, 6)
                                            .accessibilityIdentifier("native.chat.file." + file["name"].string)
                                    }
                                }
                            } label: {
                                Text("对话文件 · \(chat.files.count)").accessibilityIdentifier("native.chat.files")
                            }.font(.subheadline)
                        }
                        NativeNotice(text: chat.pollingError, isError: true)
                        NativeNotice(text: chat.error, isError: true)
                        NativeNotice(text: chat.notice)
                        NativeNotice(text: chat.draft.recoveryNotice)
                        NativeNotice(text: chat.draftStorageError, isError: true)
                        Color.clear.frame(height: composerHeight)
                        Color.clear.frame(height: 1).id("native-bottom").background(GeometryReader { geometry in Color.clear.preference(key: BottomPosition.self, value: geometry.frame(in: .named("native-transcript")).maxY) })
                        }.padding(.horizontal, 22).padding(.vertical, 24).frame(maxWidth: 820).frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("native.transcript")
                .coordinateSpace(name: "native-transcript")
                .task(id: historyLoadRequest) {
                    guard historyLoadRequest > 0, chat.hasMore, !chat.loadingOlder else { return }
                    let identity = chat.session?.identity
                    following = false
                    await chat.older(beforeApply: { historyScroll.captureAnchor() })
                    guard !Task.isCancelled, chat.session?.identity == identity else { return }
                    // Layout markers correct the exact pixel displacement as lazy rows settle.
                    await Task.yield()
                    historyScroll.finish()
                }
                .overlay(alignment: .top) { NativeHistoryIndicator(controller: historyScroll) }

                .onPreferenceChange(BottomPosition.self) { bottom in
                    bottomPosition = bottom
                    // A lazily removed bottom marker has no position; it is not at y = 0.
                    guard let bottom else { return }
                    // Content growth must not turn off an existing follow request.
                    // Only a user's drag or history action pauses following.
                    if !draggingHistory && !historyScroll.preservingHistory && bottom >= 0 && bottom <= viewport.size.height + 75 { following = true }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.visibleRows) { _ in if following && !chat.loadingOlder && !historyScroll.preservingHistory { scrollRequest += 1 } }
                .onChange(of: chat.loading) { loading in if !loading && following { scrollRequest += 1 } }
                .onChange(of: chat.notice) { notice in if !notice.isEmpty && following { scrollRequest += 1 } }
                .task(id: scrollRequest) {
                    guard scrollRequest > 0 else { return }
                    // Wait for LazyVStack to lay out the updated footer before locating it.
                    do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
                    if following && !draggingHistory && !chat.loadingOlder && !historyScroll.preservingHistory { proxy.scrollTo("native-bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following { NativeIconButton(symbol: "arrow.down", label: "回到最新消息", filled: true) { historyScroll.releaseAnchor(); following = true; withAnimation { proxy.scrollTo("native-bottom", anchor: .bottom) } }.padding(16) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            composer.background(GeometryReader { geometry in
                Color.clear.preference(key: ComposerHeight.self, value: geometry.size.height)
            })
        }
        .onPreferenceChange(ComposerHeight.self) { height in
            if height > 0 { composerHeight = height }
        }
    }
    private func processRow(_ row: NativeRow) -> some View {
        NativeToolRow(row: row, text: chat.rowText(row), stats: chat.fileChangeStats(row)) { focused = false; toolDetail = row }
            .task(id: chat.cursor(for: row) + row.version.identifier) { await chat.loadFileChangeStats(row) }
    }
    private func message(_ row: NativeRow) -> some View {
        VStack(alignment: row.role == "user" ? .trailing : .leading, spacing: 10) {
            if row.role == "user" {
                NativeSelectableText(value: AttributedString(chat.rowText(row)), accessibilityIdentifier: "native.message.selectable.user")
                    .padding(.horizontal, 18).padding(.vertical, 14).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 24)).padding(.leading, 30)
            } else if row.role == "error" { NativeNotice(text: chat.rowText(row), isError: true) }
            else { NativeChatMarkdown(text: chat.rowText(row)).font(.system(size: 16)).lineSpacing(5) }
            if let attachments = row.attachments {
                NativeFileListLayout {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                        Button { openAttachment(attachment) } label: {
                            Label(attachment["name"].string.isEmpty ? "附件" : attachment["name"].string, systemImage: "paperclip")
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }
            }
            if chat.rowHasMore(row) { Button("继续加载正文") { following = false; perform { try await chat.expand(row) } }.font(.caption) }
            if row.editable == true && !chat.readOnly {
                Button { messageAction = row } label: { Label("编辑消息", systemImage: "pencil").font(.caption) }.foregroundStyle(.secondary)
            }
            if row.role == "assistant" {
                HStack(spacing: 20) {
                    Button { UIPasteboard.general.string = chat.rowText(row) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制回复")
                    ShareLink(item: chat.rowText(row)) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享回复")
                    if row.forkable == true && !chat.readOnly { Button { messageAction = row } label: { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("从此处分支") }
                }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.role == "user" ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if chat.readOnly {
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        if chat.convertingCLI { ProgressView().controlSize(.small); Text("正在接管 CLI 会话…").font(.subheadline) }
                        else { Image(systemName: "doc.text"); Text("只读历史").font(.subheadline) }
                        Spacer()
                        if chat.logView && chat.session?.readOnly != true { Button("返回交互视图") { chat.logView = false } }
                    }
                    if !chat.conversionError.isEmpty {
                        HStack { Text(chat.conversionError).font(.caption).foregroundStyle(.red); Spacer(); Button("重试") { Task { await chat.retryCLIConversion() } }.font(.caption) }
                    }
                }.foregroundStyle(.secondary).padding(18)
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
                    Menu {
                        Button("选择照片", systemImage: "photo") { photoPicker = true }
                        Button("拍照", systemImage: "camera") { takePhoto = true }.disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        Divider()
                        Button("选择文件", systemImage: "doc") { importFile = true }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("添加附件").accessibilityIdentifier("native.attachment.menu").disabled(uploading || chat.busy)
                    TextField("", text: $chat.draft.text, prompt: Text(NativeContextUsage(contextUsage)?.placeholder ?? "上下文用量暂无数据").foregroundColor(Color(uiColor: .placeholderText)), axis: .vertical).lineLimit(1...7).font(.system(size: 16)).focused($focused).padding(.vertical, 12).accessibilityIdentifier("native.composer")
                    if uploading || chat.busy { ProgressView().frame(width: 44, height: 44) }
                    else if chat.running && chat.draft.text.isEmpty && chat.draft.attachments.isEmpty {
                        NativeIconButton(symbol: "stop.fill", label: "停止任务", filled: true) { perform { try await chat.stop() } }.disabled(!chat.connected)
                    } else {
                        NativeSendButton(enabled: chat.canSend, onSend: { sendMessage() }, onChooseMode: { focused = false; chooseSendMode = true })
                            .frame(width: 44, height: 44)
                    }
                }.padding(7).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 29))

            }
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }
    private var threadStatus: some View {
        NavigationStack {
            Form {
                Section {
                    Text(chat.meta["title"].string.isEmpty ? chat.session?.title ?? "Codex" : chat.meta["title"].string).font(.headline)
                    Label(chat.readOnly ? "只读历史" : chat.connected ? chat.running ? "执行中" : "已连接" : "等待连接", systemImage: chat.readOnly ? "doc.text" : chat.running ? "circle.dotted" : "laptopcomputer")
                    if let row = chat.session { Text(row.cwd ?? "").font(.caption).textSelection(.enabled); Text(row.hostLabel ?? row.host).font(.caption).foregroundStyle(.secondary) }
                }
                if let row = chat.session {
                    if let context = NativeContextUsage(sessionUsage["context"]) {
                        Section("上下文") {
                            LabeledContent("已用", value: NativeTokenCount.format(context.used))
                            LabeledContent("窗口", value: NativeTokenCount.format(context.window))
                            LabeledContent("占用", value: context.percentage)
                        }
                    }
                    Section("Token 用量与费用") {
                        if usageLoading { ProgressView().frame(maxWidth: .infinity) }
                        else if sessionUsage["usage"] != .null {
                            let usage = sessionUsage["usage"]
                            LabeledContent("输入", value: tokenCount(usage["input_tokens"].int))
                            LabeledContent("其中缓存", value: tokenCount(usage["cached_input_tokens"].int))
                            if usage["cache_write_input_tokens"].int > 0 { LabeledContent("缓存写入", value: tokenCount(usage["cache_write_input_tokens"].int)) }
                            LabeledContent("输出", value: tokenCount(usage["output_tokens"].int))
                            if usage["reasoning_output_tokens"].int > 0 { LabeledContent("其中推理", value: tokenCount(usage["reasoning_output_tokens"].int)) }
                            LabeledContent("合计", value: tokenCount(usage["total_tokens"].int))
                            if case .number = usage["estimatedCostUSD"] {
                                LabeledContent("API 参考费用", value: costText(usage["estimatedCostUSD"]))
                                    .accessibilityIdentifier("native.usage.cost")
                            } else {
                                LabeledContent("API 参考费用", value: "部分用量无法估价")
                            }
                            if !usage["pricingBreakdown"].array.isEmpty {
                                DisclosureGroup("模型与档位明细") {
                                    ForEach(Array(usage["pricingBreakdown"].array.enumerated()), id: \.offset) { _, part in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(part["model"].string.isEmpty ? "未知模型" : part["model"].string).font(.subheadline)
                                            LabeledContent(part["serviceTier"].string, value: costText(part["estimatedCostUSD"]))
                                            Text("输入 \(tokenCount(part["input_tokens"].int)) · 缓存 \(tokenCount(part["cached_input_tokens"].int)) · 输出 \(tokenCount(part["output_tokens"].int))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.padding(.vertical, 3)
                                    }
                                }.accessibilityIdentifier("native.usage.breakdown")
                            }
                            Text("按各轮模型、服务档位和缓存用量套用公开短上下文 API 单价，推理已含在输出中。非账户账单；未计工具、长上下文或地区附加费用，缓存写入缺少保留时长时无法估价。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let source = URL(string: usage["pricingSource"].string), source.scheme == "https" {
                                Link("OpenAI 价格 · " + usage["pricingCheckedOn"].string, destination: source).font(.caption)
                            }
                        } else {
                            Text(sessionUsage["unavailable"].string.isEmpty ? "日志尚未记录 token 用量。" : sessionUsage["unavailable"].string)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
    private func openAttachment(_ attachment: JSONValue) {
        if !attachment["uploadId"].string.isEmpty {
            download(attachment, resource: "uploads/" + attachment["uploadId"].string + "/preview", original: true)
        } else if !attachment["desktopId"].string.isEmpty {
            download(attachment, resource: "desktop-images/" + attachment["desktopId"].string)
        } else if let file = chat.files.first(where: { file in
            (!attachment["id"].string.isEmpty && file["id"] == attachment["id"])
                || (!attachment["path"].string.isEmpty && NativeMessageLinks.normalized(file["reference"].string) == NativeMessageLinks.normalized(attachment["path"].string))
        }) { download(file) }
        else { actionError = "此附件已过期，或当前会话没有可下载的文件记录。" }
    }
    private func download(_ file: JSONValue, resource: String? = nil, original: Bool = false) {
        guard let session = chat.session else { return }
        let identifier = resource ?? ("files/" + file["id"].string)
        guard resource != nil || !file["id"].string.isEmpty, downloading.insert(identifier).inserted else { return }
        Task {
            defer { downloading.remove(identifier) }
            do {
                var query = ["host": session.host]
                if original { query["variant"] = "original" }
                let url = try await chat.api.download("/api/sessions/\(session.id)/\(identifier)", query: query, name: file["name"].string)
                do {
                    let content = try await Task.detached(priority: .userInitiated) { try NativePreviewContent.read(url) }.value
                    guard chat.session?.identity == session.identity else { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return }
                    if let content { preview = NativePreviewFile(url: url, content: content) }
                    else { share = ShareFile(url: url) }
                } catch {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error
                }
            } catch { actionError = error.localizedDescription }
        }
    }
    private func loadSessionUsage(_ row: LinkSession) async {
        usageLoading = true
        defer { usageLoading = false }
        do { sessionUsage = try await chat.api.value("/api/native/v1/threads/\(row.id)/usage", query: ["host": row.host]) }
        catch { sessionUsage = json(["unavailable": string(error.localizedDescription)]) }
    }
    private func tokenCount(_ count: Int) -> String {
        NativeTokenCount.format(count)
    }
    private func costText(_ value: JSONValue) -> String {
        guard case .number(let amount) = value else { return "无法估价" }
        return String(format: amount > 0 && amount < 0.0001 ? "$%.6f USD" : "$%.4f USD", amount)
    }
    private func uploadImage(_ data: Data, name: String) async throws {
        guard data.count <= 20 * 1024 * 1024 else { throw LinkError.message("图片不能超过 20 MB") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        uploading = true
        defer { uploading = false }
        try await chat.upload(url, name: name)
    }
    private func perform(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { actionError = error.localizedDescription } } }
}
private struct NativeCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator
        picker.cameraCaptureMode = .photo; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: dismiss) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction
        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) { self.onImage = onImage; self.dismiss = dismiss }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }; dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
private struct BottomPosition: PreferenceKey { static var defaultValue: CGFloat? = nil; static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value } }
private struct ComposerHeight: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) } }

struct NativeModelEfforts {
    let values: [String]
    let preferred: String
    init(catalog: JSONValue, model: String) {
        let row = catalog["models"].array.first { $0["id"].string == model } ?? .null
        let supported = row["efforts"].array.map(\.string).filter { !$0.isEmpty }
        values = supported.isEmpty ? ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"] : supported
        let defaultValue = row["defaultEffort"].string
        preferred = values.contains(defaultValue) ? defaultValue : values.contains("medium") ? "medium" : values[0]
    }
    func selection(_ current: String) -> String { values.contains(current) ? current : preferred }
}

struct NativeThreadSettings: View {
    @ObservedObject var chat: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: JSONValue = .null
    @State private var model = ""
    @State private var effort = "medium"
    @State private var fast = false
    @State private var busy = false
    @State private var loading = true
    @State private var error = ""
    private var efforts: NativeModelEfforts { NativeModelEfforts(catalog: catalog, model: model) }
    var body: some View {
        NavigationStack {
            Form {
                Section("当前会话") {
                    TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !catalog["models"].array.isEmpty {
                        Picker("可用模型", selection: $model) {
                            if !catalog["models"].array.contains(where: { $0["id"].string == model }) { Text(model.isEmpty ? "选择模型" : model).tag(model) }
                            ForEach(Array(catalog["models"].array.enumerated()), id: \.offset) { _, row in Text(row["name"].string.isEmpty ? row["id"].string : row["name"].string).tag(row["id"].string) }
                        }.pickerStyle(.menu).accessibilityIdentifier("native.thread.model")
                    }
                    Picker("推理强度", selection: $effort) {
                        ForEach(efforts.values, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu).disabled(loading).accessibilityIdentifier("native.thread.effort")
                    if loading { ProgressView("正在读取模型选项…") }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }; ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(busy || loading || model.isEmpty || !chat.connected) } }
            .task {
                model = chat.meta["model"].string; effort = chat.meta["effort"].string; fast = chat.meta["serviceTier"].string == "fast"
                do { if let row = chat.session { catalog = try await chat.api.value("/api/sessions/\(row.id)/catalog", query: ["host": row.host]) } } catch { self.error = error.localizedDescription }
                effort = efforts.selection(effort); loading = false
            }
            .onChange(of: model) { _ in if !loading { effort = efforts.selection(effort) } }
            .interactiveDismissDisabled(busy)
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
