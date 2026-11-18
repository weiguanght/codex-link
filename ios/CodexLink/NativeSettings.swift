import SwiftUI

struct NativeAppSettings: View {
    @ObservedObject var connection: Connection
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("应用") {
                NavigationLink { NativeReadingSettings() } label: {
                    entry("界面与消息", detail: "主题、后续消息、命令与差异换行", icon: "text.bubble", color: .blue)
                }
            }
            if workspace.api.ready {
                Section("Mac 上的 Codex") {
                    category(.models, detail: "默认模型、计划推理与上下文压缩", icon: "cpu", color: .purple)
                    category(.permissions, detail: "命令审批、审核方式与执行沙盒", icon: "shield", color: .orange)
                    category(.instructions, detail: "开发者指令、环境信息与记忆", icon: "doc.text", color: .indigo)
                    category(.tools, detail: "联网搜索、终端、Skills 与 MCP", icon: "wrench.and.screwdriver", color: .teal)
                    category(.history, detail: "CLI 输入历史与容量", icon: "clock.arrow.circlepath", color: .blue)
                }
            }
            Section("连接与高级") {
                NavigationLink { NativeMacConnectionSettings(connection: connection) } label: {
                    entry("Mac 连接", detail: connection.status, icon: "desktopcomputer", color: .blue)
                }
                if workspace.api.ready {
                    NavigationLink { NativeAccountsView(api: workspace.api) } label: {
                        entry("账号与接入", detail: "查看和切换 Mac 上的接入", icon: "person.crop.circle", color: .purple)
                    }
                    NavigationLink { NativeAdvancedSettings(api: workspace.api) } label: {
                        entry("高级配置", detail: "直接编辑 config.toml", icon: "curlybraces", color: .gray)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }

    private func category(_ category: CodexSettingsCategory, detail: String, icon: String, color: Color) -> some View {
        NavigationLink {
            NativeCodexSettings(api: workspace.api, category: category)
        } label: {
            entry(category.title, detail: detail, icon: icon, color: color)
        }
    }

    private func entry(_ title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct NativeReadingSettings: View {
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage("native.followUpBehavior") private var followUpBehavior = "queue"
    @AppStorage("native.commandLineWrapping") private var commandLineWrapping = true
    @AppStorage("native.diffLineWrapping") private var diffLineWrapping = true

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            }
            Section {
                Picker("后续消息默认方式", selection: Binding(get: { NativeSendMode.followUp(followUpBehavior) }, set: { followUpBehavior = $0 })) {
                    Text("完成后发送").tag("queue")
                    Text("补充当前任务").tag("steer")
                }
            } footer: {
                Text("仅用于任务执行期间。任务结束后直接发送。")
            }
            Section("代码阅读") {
                Toggle("命令与输出自动换行", isOn: $commandLineWrapping)
                    .accessibilityIdentifier("native.settings.commandWrapping")
                Toggle("文件变更自动换行", isOn: $diffLineWrapping)
            }
        }
        .navigationTitle("界面与消息").navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeMacConnectionSettings: View {
    @ObservedObject var connection: Connection
    @State private var forget = false

    var body: some View {
        Form {
            Section("连接状态") {
                Label(connection.status, systemImage: connection.online ? "checkmark.circle" : "network.slash")
                if let url = connection.connectedURL {
                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                }
                Button("重新探测地址") { connection.reconnect() }
            }
            if let peer = connection.peer {
                Section("已配对的 Mac") {
                    LabeledContent("名称", value: peer.name)
                    NavigationLink("地址与身份") {
                        Form {
                            Section("局域网") { Text(peer.ipv4.joined(separator: "\n")).textSelection(.enabled) }
                            Section("公网 IPv6") { Text(peer.ipv6.isEmpty ? "尚未发现" : peer.ipv6.joined(separator: "\n")).textSelection(.enabled) }
                            Section("设备 ID") { Text(peer.deviceId).font(.caption).textSelection(.enabled) }
                            Section("证书 SHA-256") { Text(peer.pin).font(.caption2).textSelection(.enabled) }
                        }.navigationTitle("地址与身份").navigationBarTitleDisplayMode(.inline)
                    }
                    Button("忘记此 Mac", role: .destructive) { forget = true }
                }
            }
        }
        .navigationTitle("Mac 连接").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("忘记后需要回到局域网重新配对", isPresented: $forget, titleVisibility: .visible) {
            Button("忘记此 Mac", role: .destructive) { connection.forget() }
        } message: { Text("忘记此 Mac 会清除本机配对凭据和输入草稿。") }
    }
}

enum CodexSettingsCategory: CaseIterable {
    case models, permissions, instructions, tools, history

    var title: String {
        switch self {
        case .models: return "模型与推理"
        case .permissions: return "权限与沙盒"
        case .instructions: return "指令与记忆"
        case .tools: return "工具与终端"
        case .history: return "历史与存储"
        }
    }

    var sections: [CodexSettingsSection] {
        switch self {
        case .models:
            return [
                .init("模型", [("model", "默认模型"), ("review_model", "代码审查模型"), ("service_tier", "服务档位")]),
                .init("回答", [("model_reasoning_effort", "推理强度"), ("plan_mode_reasoning_effort", "计划模式推理强度"),
                               ("model_reasoning_summary", "推理摘要"), ("model_verbosity", "回答详略"), ("personality", "交流风格")]),
                .init("上下文", [("model_context_window", "上下文窗口（Token）"),
                                 ("model_auto_compact_token_limit", "自动压缩阈值（Token）"),
                                 ("model_auto_compact_token_limit_scope", "自动压缩范围"),
                                 ("model_post_turn_compact_threshold_percent", "回合结束压缩阈值（%）")],
                      note: "回合结束压缩阈值接受 0–100，设为 0 时关闭。")
            ]
        case .permissions:
            return [
                .init("审批与沙盒", [("approval_policy", "审批策略"), ("approvals_reviewer", "由谁审核"),
                                     ("sandbox_mode", "执行沙盒"), ("allow_login_shell", "允许使用登录 Shell")])
            ]
        case .instructions:
            return [
                .init("指令", [("developer_instructions", "开发者指令"), ("compact_prompt", "上下文压缩指令"),
                              ("project_doc_max_bytes", "项目指令读取上限（字节）")]),
                .init("注入到模型的上下文", [("include_environment_context", "工作环境"), ("include_environment_context_time", "当前日期与时区"),
                                             ("include_apps_instructions", "应用指令"), ("include_collaboration_mode_instructions", "协作模式指令")]),
                .init("记忆", [("features.memories", "启用记忆"), ("memories.generate_memories", "生成记忆"),
                              ("memories.use_memories", "使用记忆"), ("memories.disable_on_external_context", "使用外部上下文时停用记忆")],
                      note: "开启记忆后，Codex 才会按下方配置生成和使用记忆。")
            ]
        case .tools:
            return [
                .init("工具", [("web_search", "联网搜索"), ("tool_output_token_limit", "工具输出上限（Token）")]),
                .init("终端", [("background_terminal_max_timeout", "后台终端等待上限（毫秒）")])
            ]
        case .history:
            return [
                .init("CLI 输入历史", [("history.persistence", "保存方式"), ("history.max_bytes", "历史文件上限（字节）")],
                      note: "此项控制 CLI 输入记录 history.jsonl。会话和聊天记录另行保存。")
            ]
        }
    }
}

struct CodexSettingsSection {
    let title: String
    let rows: [(key: String, label: String)]
    let note: String?

    init(_ title: String, _ rows: [(String, String)], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }
}

struct NativeCodexSettings: View {
    let api: NativeAPI
    var initialScope = ""
    var category: CodexSettingsCategory?

    @Environment(\.dismiss) private var dismiss
    @State private var value: JSONValue = .null
    @State private var draft: [String: String] = [:]
    @State private var busy = false
    @State private var stale = false
    @State private var error = ""
    @State private var status = ""
    @State private var permissions = false
    @State private var discard = false
    @State private var close = false
    @State private var models: [JSONValue] = []

    private var sections: [CodexSettingsSection] {
        (category.map { [$0] } ?? CodexSettingsCategory.allCases).flatMap(\.sections)
    }
    private var changes: [String: JSONValue] {
        draft.reduce(into: [:]) { result, entry in
            let (key, text) = entry
            guard value["fields"][key]["editable"].bool else { return }
            switch value["fields"][key]["kind"].string {
            case "boolean": result[key] = text.isEmpty ? .null : .bool(text == "true")
            case "integer": result[key] = text.isEmpty ? .null : Int(text).map { .number(Double($0)) }
            default: result[key] = text.isEmpty ? .null : .string(text)
            }
        }
    }
    private var invalidNumber: String? {
        sections.lazy.flatMap(\.rows).first { row in
            let field = value["fields"][row.key]
            guard field["kind"].string == "integer", let text = draft[row.key], !text.isEmpty else { return false }
            guard let number = Int(text) else { return true }
            return number < field["minimum"].int || number > (field["maximum"] == .null ? 9_007_199_254_740_991 : field["maximum"].int)
        }?.label
    }

    var body: some View {
        Form {
            if !initialScope.isEmpty {
                Section { LabeledContent("项目", value: value["scope"]["name"].string) }
            }
            if !value["reason"].string.isEmpty || !error.isEmpty || !status.isEmpty || invalidNumber != nil {
                Section {
                    NativeNotice(text: value["reason"].string)
                    NativeNotice(text: error, isError: true)
                    NativeNotice(text: status)
                    if let invalidNumber { NativeNotice(text: "\(invalidNumber)超出取值范围。", isError: true) }
                }
            }
            if value != .null {
                ForEach(sections, id: \.title) { section in
                    let rows = section.rows.filter { isVisible($0.key) }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows, id: \.key) { row in field(row.key, label: row.label) }
                            if initialScope.isEmpty, rows.contains(where: { $0.key == "model" }), value["capabilities"]["models"].bool, models.isEmpty {
                                Button("读取模型目录") { perform { try await loadModels() } }
                            }
                        } header: {
                            Text(section.title)
                        } footer: {
                            if let note = section.note { Text(note) }
                        }
                    }
                }
                if category == .tools {
                    Section("扩展") {
                        if value["capabilities"]["skills"].bool {
                            NavigationLink("Skills") { NativeSkillsView(api: api, scope: initialScope) }
                        }
                        if value["capabilities"]["mcp"].bool {
                            NavigationLink("MCP 服务") { NativeMCPView(api: api) }
                        }
                    }
                }
            }
            Section {
                Button {
                    if draft.isEmpty { Task { await read() } } else { discard = true }
                } label: { Label("重新读取", systemImage: "arrow.clockwise") }
            } footer: {
                if initialScope.isEmpty, value["writable"].bool { Text("修改适用于之后加载配置的会话。") }
            }
        }
        .navigationTitle(category?.title ?? "项目配置").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if draft.isEmpty { dismiss() } else { close = true }
                } label: { Label("返回", systemImage: "chevron.left") }
                .disabled(busy)
            }
            if initialScope.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if changes.keys.contains(where: needsConfirmation) { permissions = true }
                        else { perform { try await save() } }
                    }
                    .disabled(busy || stale || changes.isEmpty || invalidNumber != nil || !value["writable"].bool)
                    .accessibilityIdentifier("native.settings.save")
                }
            }
        }
        .disabled(busy)
        .overlay { if busy && value == .null { ProgressView("读取配置…") } }
        .interactiveDismissDisabled(!draft.isEmpty || busy)
        .task { await read() }
        .confirmationDialog("确认修改执行权限？", isPresented: $permissions, titleVisibility: .visible) {
            Button("确认并保存") { perform { try await save(confirmPermissions: true) } }
        } message: { Text("此设置会影响 Codex 之后的命令审批或执行范围。") }
        .confirmationDialog("放弃草稿并返回？", isPresented: $close, titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("放弃未保存的配置草稿？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃并重新读取", role: .destructive) { Task { await read() } }
            Button("保留草稿", role: .cancel) {}
        }
    }

    private func isVisible(_ key: String) -> Bool {
        let field = value["fields"][key]
        return field != .null && field["supported"] != .bool(false)
    }

    private func needsConfirmation(_ key: String) -> Bool {
        value["fields"][key]["confirm"].bool || key == "approval_policy" || key == "sandbox_mode"
    }

    private func current(_ key: String) -> String {
        let field = value["fields"][key]
        let current = field["effective"] == .null ? field["value"] : field["effective"]
        switch current {
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return Int(exactly: number).map { String($0) } ?? ""
        default: return current.string
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key] ?? current(key) },
                set: { draft[key] = $0 == current(key) ? nil : $0 })
    }

    @ViewBuilder private func field(_ key: String, label: String) -> some View {
        let field = value["fields"][key]
        let input = binding(key)
        VStack(alignment: .leading, spacing: 6) {
            switch field["kind"].string {
            case "choice", "boolean":
                let choices = field["kind"].string == "boolean" ? ["true", "false"] : field["choices"].array.map(\.string)
                Picker(label, selection: input) {
                    Text("默认").tag("")
                    ForEach(choices, id: \.self) { Text(optionLabel($0)).tag($0) }
                    if !input.wrappedValue.isEmpty && !choices.contains(input.wrappedValue) {
                        Text(optionLabel(input.wrappedValue)).tag(input.wrappedValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("native.setting.\(key)")
            case "multiline":
                Text(label)
                TextEditor(text: input)
                    .frame(minHeight: 88)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("native.setting.\(key)")
            default:
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("默认", text: input)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(field["kind"].string == "integer" ? .numberPad : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel(label)
                            .accessibilityIdentifier("native.setting.\(key)")
                        if let options = suggestions(key), !options.isEmpty {
                            Menu {
                                ForEach(options, id: \.value) { option in
                                    Button(option.label) { input.wrappedValue = option.value }
                                }
                            } label: { Image(systemName: "chevron.down.circle") }
                            .accessibilityLabel("选择\(label)")
                        }
                    }
                } label: { Text(label) }
            }
            if !field["reason"].string.isEmpty && field["reason"] != value["reason"] {
                Text(field["reason"].string).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!field["editable"].bool)
    }

    private func suggestions(_ key: String) -> [(label: String, value: String)]? {
        if key == "model" || key == "review_model" {
            return models.map { ($0["name"].string, $0["id"].string) }
        }
        guard key == "model_reasoning_effort" || key == "plan_mode_reasoning_effort" else { return nil }
        let selected = binding("model").wrappedValue
        let model = models.first { selected.isEmpty ? $0["isDefault"].bool : $0["id"].string == selected }
        return model?["efforts"].array.map { (optionLabel($0.string), $0.string) }
    }

    private func optionLabel(_ value: String) -> String {
        Self.optionLabels[value] ?? value
    }

    private static let optionLabels = [
        "true": "开启", "false": "关闭", "disabled": "关闭", "none": "无", "auto": "自动",
        "cached": "缓存搜索", "live": "实时搜索", "untrusted": "不受信任时审批", "on-request": "按需审批",
        "never": "从不审批", "read-only": "只读", "workspace-write": "工作区可写", "danger-full-access": "完全访问",
        "user": "用户", "auto_review": "自动审核", "guardian_subagent": "审核子代理",
        "total": "完整上下文", "body_after_prefix": "仅计算前缀后的内容", "save-all": "全部保存",
        "default": "标准", "fast": "快速", "priority": "快速", "flex": "灵活",
        "friendly": "友好", "pragmatic": "务实", "minimal": "极低", "low": "低", "medium": "中",
        "high": "高", "xhigh": "极高", "concise": "简要", "detailed": "详细"
    ]

    private func accept(_ result: JSONValue) {
        value = result
        draft = [:]
        stale = false
    }

    private func loadModels() async throws {
        let result = try await api.value("/api/codex-settings/models")
        models = result["models"].array
        if models.isEmpty { status = "模型目录为空。可以手动输入模型 ID。" }
    }

    private func read() async {
        guard !busy else { return }
        busy = true
        error = ""
        status = ""
        defer { busy = false }
        do { accept(try await api.value("/api/codex-settings", query: ["scope": initialScope])) }
        catch { self.error = error.localizedDescription }
    }

    private func save(confirmPermissions: Bool = false) async throws {
        do {
            let result = try await api.value("/api/codex-settings", body: json([
                "scope": .string(initialScope), "revision": value["revision"],
                "changes": json(changes), "confirmPermissions": .bool(confirmPermissions)
            ]))
            accept(result["settings"])
            status = result["status"].string == "saved_overridden" ? "已保存。部分值受 Mac 配置或策略限制，页面显示当前生效值。" : "已保存到 Mac。"
        } catch {
            stale = true
            status = "草稿已保留。请重新读取 Mac 配置后再保存。"
            throw error
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = ""
        status = ""
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct NativeAdvancedSettings: View {
    let api: NativeAPI
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var content = ""
    @State private var original = ""
    @State private var revision = ""
    @State private var busy = false
    @State private var error = ""
    @State private var status = ""
    @State private var confirmSave = false
    @State private var confirmDiscard = false
    @State private var leave = false
    private var dirty: Bool { content != original }

    var body: some View {
        Form {
            Section("Mac 配置文件") {
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("直接编辑 Codex 用户级 TOML。保存前检查语法、字段类型和文件版本，再原子写入 Mac 文件；当前任务不会改变，Codex 重新读取配置后生效。未知或已废弃字段可能被当前版本忽略。文件内容可能包含接入信息。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("TOML") {
                NativeCodeView(text: $content, language: "toml", editable: true, wrapsLines: false,
                               identifier: "native.settings.advanced.editor")
                    .frame(minHeight: 380)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                NativeNotice(text: error, isError: true)
                NativeNotice(text: status)
                Button { requestReload() } label: { Label("重新读取", systemImage: "arrow.clockwise") }.disabled(busy)
            }
        }
        .navigationTitle("高级配置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { if dirty { leave = true } else { dismiss() } }.disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { confirmSave = true }.disabled(busy || revision.isEmpty || !dirty)
                    .accessibilityIdentifier("native.settings.advanced.save")
            }
        }
        .disabled(busy)
        .overlay { if busy && revision.isEmpty { ProgressView("读取配置…") } }
        .interactiveDismissDisabled(dirty || busy)
        .task { await read() }
        .confirmationDialog("保存 Mac 的 Codex 配置？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("验证并写入 config.toml") { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: { Text("只修改上方显示的用户级配置文件。无效 TOML 或已变化的文件不会覆盖 Mac 上的内容。") }
        .confirmationDialog("放弃未保存的配置？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃并重新读取", role: .destructive) { Task { await read() } }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("放弃未保存的配置？", isPresented: $leave, titleVisibility: .visible) {
            Button("放弃并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    private func requestReload() {
        if dirty { confirmDiscard = true } else { Task { await read() } }
    }

    private func read() async {
        guard !busy else { return }
        busy = true; error = ""; defer { busy = false }
        do { accept(try await api.value("/api/codex-settings/advanced")); status = "已读取 Mac 配置文件" }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard !busy, !revision.isEmpty else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            let result = try await api.value("/api/codex-settings/advanced", body: json(["revision": string(revision), "content": string(content)]))
            accept(result); status = result["status"].string == "unchanged" ? "文件没有变化" : "已写入 Mac 配置文件"
        } catch {
            self.error = error.localizedDescription
            status = "草稿已保留。请重新读取并合并后再保存。"
        }
    }

    private func accept(_ value: JSONValue) {
        path = value["path"].string
        content = value["content"].string
        original = content
        revision = value["revision"].string
    }
}

struct NativeSkillsView: View {
    let api: NativeAPI
    let scope: String
    @State private var value: JSONValue = .null
    @State private var target: JSONValue?
    @State private var busy = false
    @State private var stale = false
    @State private var error = ""
    var body: some View {
        List {
            Section { Text(value["notice"].string.isEmpty ? "技能开关写入用户级配置。" : value["notice"].string).font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(value["skills"].array.enumerated()), id: \.offset) { _, skill in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(skill["name"].string).font(.headline); Spacer(); Image(systemName: skill["enabled"].bool ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                    Text(skill["description"].string).font(.subheadline).foregroundStyle(.secondary)
                    Text(skill["path"].string).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    Button(skill["enabled"].bool ? "禁用技能" : "启用技能") { target = skill }.font(.subheadline).disabled(busy || stale || !value["writable"].bool)
                }.padding(.vertical, 8)
            }
            if value != .null && value["skills"].array.isEmpty { Text("没有可用技能").foregroundStyle(.secondary) }
            NativeNotice(text: value["reason"].string)
            NativeNotice(text: error, isError: true)
            Button("重新读取") { Task { await read() } }.disabled(busy)
        }
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline).task { await read() }
        .confirmationDialog("修改全局技能开关？", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
            if let target { Button(target["enabled"].bool ? "确认禁用" : "确认启用") { Task { await toggle(target) } } }
        } message: { Text("影响后续加载此技能的会话，不卸载当前任务中的技能。") }
    }
    private func read() async { busy = true; defer { busy = false }; do { value = try await api.value("/api/codex-settings/skills", query: ["scope": scope]); error = ""; stale = false } catch { self.error = error.localizedDescription } }
    private func toggle(_ row: JSONValue) async {
        busy = true; defer { busy = false }
        do { value = try await api.value("/api/codex-settings/skills", body: json(["scope": string(scope), "revision": value["revision"], "path": row["path"], "enabled": .bool(!row["enabled"].bool), "confirmed": .bool(true)])); error = "" }
        catch { self.error = error.localizedDescription + "。请重新读取后检查状态。"; stale = true }
    }
}

struct NativeMCPView: View {
    let api: NativeAPI
    @State private var value: JSONValue = .null
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            Section { Text("读取设置查询进程的 MCP 状态，可能连接已配置的服务。").font(.footnote).foregroundStyle(.secondary); Button("读取 MCP 状态") { Task { await read() } }.disabled(busy); if busy { ProgressView() } }
            ForEach(Array(value["servers"].array.enumerated()), id: \.offset) { _, server in
                VStack(alignment: .leading, spacing: 6) { Text(server["name"].string).font(.headline); Text(server["authStatus"].string + " · \(server["toolCount"].int) 个工具").font(.caption).foregroundStyle(.secondary); if server["discoveryError"].bool { Text("工具发现失败").font(.caption).foregroundStyle(.orange) } }
            }
            if value != .null && value["servers"].array.isEmpty { Text("未配置 MCP 服务").foregroundStyle(.secondary) }
            NativeNotice(text: value["notice"].string); NativeNotice(text: error, isError: true)
        }.navigationTitle("MCP 服务").navigationBarTitleDisplayMode(.inline)
    }
    private func read() async { busy = true; error = ""; defer { busy = false }; do { value = try await api.value("/api/codex-settings/mcp") } catch { self.error = error.localizedDescription } }
}

struct NativeAccountsView: View {
    let api: NativeAPI
    @State private var value: JSONValue = .null
    @State private var target: JSONValue?
    @State private var switchAttempt: (target: String, id: String)?
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            Section { Text("切换会重启 Mac 上的 Codex 桌面应用。添加或修改接入请在 Mac 完成。").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(value["accounts"].array.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(row["name"].string).font(.headline); Spacer(); if row["id"] == value["activeId"] { Image(systemName: "checkmark.circle.fill") } }
                    Text(row["kind"].string + " · " + row["model"].string).font(.caption).foregroundStyle(.secondary)
                    if row["id"] != value["activeId"] { Button("切换到此接入") { target = row; if switchAttempt?.target != row["id"].string { switchAttempt = (row["id"].string, UUID().uuidString.lowercased()) } }.disabled(busy || !value["canSwitch"].bool || !value["blockers"].array.isEmpty) }
                }.padding(.vertical, 6)
            }
            Section {
                ForEach(Array(value["blockers"].array.enumerated()), id: \.offset) { _, blocker in Text(blocker.pretty).font(.caption).foregroundStyle(.secondary) }
                if !value["switch"]["phase"].string.isEmpty { Text("切换状态：" + value["switch"]["phase"].string).font(.caption) }
                NativeNotice(text: error, isError: true)
                Button("刷新") { Task { await read() } }.disabled(busy)
            }
        }
        .navigationTitle("账号与接入").navigationBarTitleDisplayMode(.inline)
        .task { await read() }
        .confirmationDialog("确认任务已结束，并切换重启 Codex？", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
            if let target { Button("确认切换") { Task { busy = true; defer { busy = false }; do { value = try await api.value("/api/accounts/switch", body: json(["id": target["id"], "confirmed": .bool(true), "tasksConfirmed": .bool(true), "requestId": string(switchAttempt?.id ?? UUID().uuidString.lowercased())])); error = "" } catch { self.error = error.localizedDescription } } } }
        }
    }
    private func read() async { busy = true; defer { busy = false }; do { value = try await api.value("/api/accounts"); error = "" } catch { self.error = error.localizedDescription } }
}
