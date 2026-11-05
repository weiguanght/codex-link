import SwiftUI

struct NativeAppSettings: View {
    @ObservedObject var connection: Connection
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage("native.followUpBehavior") private var followUpBehavior = "send"
    @AppStorage("native.commandLineWrapping") private var commandLineWrapping = true
    @AppStorage("native.diffLineWrapping") private var diffLineWrapping = true
    @State private var forget = false
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "terminal").font(.title2).foregroundStyle(Color.linkCanvas).frame(width: 48, height: 48).background(Color.primary, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) { Text("Codex Link").font(.headline); Text("在你的 Mac 上执行").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            if workspace.api.ready {
                Section("Codex") {
                    NavigationLink { NativeCodexSettings(api: workspace.api, workspace: workspace, initialScope: "") } label: { Label("默认行为", systemImage: "slider.horizontal.3") }
                    NavigationLink { NativeSkillsView(api: workspace.api, scope: "") } label: { Label("Skills", systemImage: "sparkles") }
                    NavigationLink { NativeMCPView(api: workspace.api) } label: { Label("MCP 服务", systemImage: "puzzlepiece.extension") }
                    NavigationLink { NativeAccountsView(api: workspace.api) } label: { Label("账号与接入", systemImage: "person.crop.circle") }
                }
            }
            Section("外观") {
                Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
            }
            Section {
                Picker("后续消息默认方式", selection: $followUpBehavior) {
                    Text("发送新消息").tag("send")
                    Text("完成后发送").tag("queue")
                    Text("补充当前任务").tag("steer")
                }
                Toggle("命令与输出自动换行", isOn: $commandLineWrapping).accessibilityIdentifier("native.settings.commandWrapping")
                Toggle("文件变更自动换行", isOn: $diffLineWrapping)
            } header: { Text("任务与阅读") } footer: {
                Text("默认方式用于尚无草稿的新会话，当前会话仍可单独选择。输入草稿只保存在此设备；忘记 Mac 时一并清除。")
            }
            Section("连接") {
                Label(connection.status, systemImage: connection.online ? "checkmark.circle" : "network.slash").font(.subheadline)
                Button("重新探测地址") { connection.reconnect() }
                if let url = connection.connectedURL { Text(url.absoluteString).font(.caption).textSelection(.enabled) }
            }
            if let peer = connection.peer {
                Section("已记住的 Mac") {
                    LabeledContent("名称", value: peer.name)
                    NavigationLink("地址与身份") { Form {
                        Section("局域网") { Text(peer.ipv4.joined(separator: "\n")).textSelection(.enabled) }
                        Section("公网 IPv6") { Text(peer.ipv6.isEmpty ? "尚未发现" : peer.ipv6.joined(separator: "\n")).textSelection(.enabled) }
                        Section("设备 ID") { Text(peer.deviceId).font(.caption).textSelection(.enabled) }
                        Section("证书 SHA-256") { Text(peer.pin).font(.caption2).textSelection(.enabled) }
                    }.navigationTitle("地址与身份") }
                    Button("忘记此 Mac", role: .destructive) { forget = true }
                }
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .confirmationDialog("忘记后需要回到局域网重新配对", isPresented: $forget, titleVisibility: .visible) {
            Button("忘记此 Mac", role: .destructive) { connection.forget(); dismiss() }
        } message: { Text("清除本机凭据；Mac 上的旧授权需在 Mac 端撤销。") }
    }
}

struct NativeCodexSettings: View {
    let api: NativeAPI
    @ObservedObject var workspace: WorkspaceModel
    let initialScope: String
    @Environment(\.dismiss) private var dismiss
    @State private var scope = ""
    @State private var requestedScope: String?
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
    private let groups: [(String, [String])] = [("模型与推理", ["model", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity"]), ("搜索与权限", ["web_search", "approval_policy", "sandbox_mode"]), ("指令", ["developer_instructions"])]
    private let labels = ["model": "默认模型", "model_reasoning_effort": "推理强度", "model_reasoning_summary": "推理摘要", "model_verbosity": "回答详略", "web_search": "联网搜索", "approval_policy": "审批策略", "sandbox_mode": "执行沙盒", "developer_instructions": "开发者指令"]
    private var changes: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, text) in draft where value["fields"][key]["editable"].bool && text != value["fields"][key]["value"].string { result[key] = text.isEmpty ? .null : string(text) }
        return result
    }
    var body: some View {
        Form {
            Section {
                Picker("配置范围", selection: $scope) {
                    Text("全局默认设置").tag("")
                    ForEach(workspace.projects.filter { $0.registered == true && $0.host == "local" }) { Text($0.name).tag($0.key) }
                }.onChange(of: scope) { key in
                    guard key != value["scope"]["key"].string else { return }
                    requestedScope = key
                    if changes.isEmpty { Task { await read(key) } } else { discard = true }
                }
                NativeNotice(text: value["reason"].string)
                Text("保存后续会话的默认行为；当前任务不热更新。").font(.footnote).foregroundStyle(.secondary)
            }
            if !value["revision"].string.isEmpty {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { key in field(key) }
                        if group.1.contains("model") {
                            Button("读取可用模型") { perform { let result = try await api.value("/api/codex-settings/models"); models = result["models"].array; status = result["notice"].string } }
                            if !models.isEmpty {
                                Picker("选择目录模型", selection: binding("model")) { Text("选择模型").tag(""); ForEach(Array(models.enumerated()), id: \.offset) { _, row in Text(row["name"].string).tag(row["id"].string) } }.disabled(!value["fields"]["model"]["editable"].bool)
                            }
                        }
                    }
                }
                Section("来源") {
                    Text(value["runtimeVersion"].string).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(value["layers"].array.enumerated()), id: \.offset) { _, layer in Text(source(layer)).font(.caption).textSelection(.enabled) }
                }
            }
            Section {
                NativeNotice(text: error, isError: true); NativeNotice(text: status)
                Button { if changes.isEmpty { Task { await read(scope) } } else { requestedScope = scope; discard = true } } label: { Label("重新读取", systemImage: "arrow.clockwise") }
            }
        }
        .navigationTitle(scope.isEmpty ? "Codex 默认行为" : "项目有效配置").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("返回") { if changes.isEmpty { dismiss() } else { close = true } }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                if changes.keys.contains(where: { ["approval_policy", "sandbox_mode"].contains($0) }) { permissions = true }
                else { perform { try await save() } }
            }.disabled(busy || stale || changes.isEmpty || !value["writable"].bool).accessibilityIdentifier("native.settings.save") }
        }
        .disabled(busy)
        .overlay { if busy && value == .null { ProgressView("读取配置…") } }
        .interactiveDismissDisabled(!changes.isEmpty || busy)
        .task { scope = initialScope; await read(initialScope) }
        .confirmationDialog("确认修改执行权限？", isPresented: $permissions, titleVisibility: .visible) {
            Button("确认并保存") { perform { try await save(confirmPermissions: true) } }
        } message: { Text("完全访问或从不审批会扩大 Codex 的执行能力。变更作用于之后加载配置的会话。") }
        .confirmationDialog("放弃草稿并返回？", isPresented: $close, titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("放弃未保存的配置草稿？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃并重新读取", role: .destructive) { Task { await read(requestedScope ?? scope) } }
            Button("保留草稿", role: .cancel) { scope = value["scope"]["key"].string }
        }
    }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 }) }
    @ViewBuilder private func field(_ key: String) -> some View {
        let field = value["fields"][key]
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(labels[key] ?? key).font(.subheadline.weight(.medium)); Spacer(); Button("继承") { draft[key] = "" }.font(.caption).disabled(!field["editable"].bool) }
            if field["kind"].string == "choice" {
                Picker(labels[key] ?? key, selection: binding(key)) {
                    Text("继承默认值").tag("")
                    ForEach(field["choices"].array.map(\.string), id: \.self) { Text($0).tag($0) }
                    if let current = draft[key], !current.isEmpty && !field["choices"].array.contains(string(current)) { Text(current).tag(current) }
                }.labelsHidden().disabled(!field["editable"].bool)
            } else if field["kind"].string == "multiline" {
                TextEditor(text: binding(key)).frame(minHeight: 120).disabled(!field["editable"].bool).accessibilityLabel(labels[key] ?? key)
            } else {
                TextField("继承默认值", text: binding(key)).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!field["editable"].bool).accessibilityIdentifier("native.setting.\(key)")
            }
            DisclosureGroup("生效值与来源") {
                Text(field["structured"].bool ? "高级结构化设置，请在 Mac 管理" : (field["effective"] == .null ? "运行时默认" : field["effective"].string)).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(source(field["origin"])).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
            if !field["reason"].string.isEmpty && field["reason"] != value["reason"] { Text(field["reason"].string).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private func source(_ value: JSONValue) -> String { [value["type"].string, value["profile"].string, value["file"].string, value["dotCodexFolder"].string].filter { !$0.isEmpty }.joined(separator: " · ") }
    private func accept(_ result: JSONValue) { value = result; draft = result["fields"].object.mapValues { scope.isEmpty ? $0["value"].string : $0["effective"].string }; stale = false; scope = result["scope"]["key"].string }
    private func read(_ key: String) async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        do { let result = try await api.value("/api/codex-settings", query: ["scope": key]); scope = key; accept(result); status = "已读取 Mac 配置" }
        catch { self.error = error.localizedDescription; scope = value["scope"]["key"].string }
    }
    private func save(confirmPermissions: Bool = false) async throws {
        do {
            let result = try await api.value("/api/codex-settings", body: json(["scope": string(value["scope"]["key"].string), "revision": value["revision"], "changes": json(changes), "confirmPermissions": .bool(confirmPermissions)]))
            accept(result["settings"]); status = result["status"].string == "saved_overridden" ? "已保存，但被更高优先级配置覆盖，请检查生效值。" : "已保存并回读确认。"
        } catch { stale = true; status = "草稿已保留。请重新读取确认实际值后再保存。"; throw error }
    }
    private func perform(_ action: @escaping () async throws -> Void) { guard !busy else { return }; busy = true; error = ""; Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } } }
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
