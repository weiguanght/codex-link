import SwiftUI

struct NativeApprovalView: View {
    @ObservedObject var chat: ChatModel
    let request: JSONValue
    @State private var answers: [String: String] = [:]
    @State private var busy = false
    @State private var error = ""
    private var method: String { request["method"].string }
    private var params: JSONValue { request["params"] }
    private var isInput: Bool { method.contains("requestUserInput") }
    private var basicApproval: Bool { method.contains("commandExecution") || method.contains("fileChange") || method.contains("permissions") }
    private var supported: Bool { request["supported"].bool && params["computerUse"] == .null && (isInput || basicApproval) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isInput ? "Codex 需要你的回复" : method.contains("fileChange") ? "允许修改文件？" : method.contains("commandExecution") ? "允许运行命令？" : "待确认请求", systemImage: "hand.raised").font(.headline)
            if !params["reason"].string.isEmpty { Text(params["reason"].string).font(.subheadline) }
            if params["command"] != .null { Text(params["command"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if params["permissions"] != .null { Text(params["permissions"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if isInput && supported {
                ForEach(Array(params["questions"].array.enumerated()), id: \.offset) { _, question in
                    let key = question["id"].string
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question["question"].string).font(.subheadline)
                        if !question["options"].array.isEmpty {
                            ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                                Button { answers[key] = option["label"].string } label: {
                                    HStack(alignment: .top) { Image(systemName: answers[key] == option["label"].string ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading, spacing: 4) { Text(option["label"].string); if !option["description"].string.isEmpty { Text(option["description"].string).font(.caption).foregroundStyle(.secondary) } } }
                                }.buttonStyle(.plain)
                            }
                        }
                        TextField("输入你的回复", text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if supported {
                if chat.wasResponded(request) { Text("已发送，等待 Mac 确认…").font(.caption).foregroundStyle(.secondary) }
                else {
                    HStack {
                        if isInput { Button("提交回复") { submitAnswers() }.buttonStyle(.borderedProminent).tint(.primary) }
                        else {
                            if allows("decline") { Button("拒绝", role: .destructive) { respond(json(["decision": string("decline")])) }.buttonStyle(.bordered) }
                            Spacer()
                            if allows("accept") { Button("本次允许") { respond(json(["decision": string("accept")])) }.buttonStyle(.borderedProminent).tint(.primary) }
                        }
                    }.disabled(busy)
                }
            } else { Text("此类请求请在 Mac 端处理。").font(.subheadline).foregroundStyle(.secondary) }
            NativeNotice(text: error, isError: true)
        }.padding(18).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 20))
    }
    private func allows(_ decision: String) -> Bool { params["availableDecisions"] == .null || params["availableDecisions"].array.contains(string(decision)) }
    private func submitAnswers() {
        var fields: [String: JSONValue] = [:]
        for question in params["questions"].array {
            let key = question["id"].string, value = (answers[question["id"].string] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { error = "请回答所有问题"; return }
            fields[key] = .array([string(value)])
        }
        respond(json(["answers": json(fields)]))
    }
    private func respond(_ response: JSONValue) {
        busy = true; error = ""
        Task { defer { busy = false }; do { try await chat.respond(request, response: response) } catch { self.error = error.localizedDescription } }
    }
}
