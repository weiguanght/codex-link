import SwiftUI
import UIKit

@MainActor
enum NativeRequestKeyboard {
    static func dismiss() {
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct NativeAgentRequest: Identifiable {
    let value: JSONValue
    var id: String { value["id"].identifier }
}

/// Owned by ChatModel, so polling and transcript cell reuse cannot erase replies.
@MainActor
final class NativeRequestDraft: ObservableObject {
    @Published var answers: [String: String] = [:]
    @Published var error = ""
}

@MainActor
struct NativeApprovalView: View {
    @ObservedObject var chat: ChatModel
    let request: JSONValue
    @ObservedObject private var draft: NativeRequestDraft

    init(chat: ChatModel, request: JSONValue) {
        self.chat = chat; self.request = request; self.draft = chat.requestDraft(request)
    }
    private var id: String { request["id"].identifier }
    private var method: String { request["method"].string }
    private var params: JSONValue { request["params"] }
    private var isInput: Bool { method.contains("requestUserInput") }
    private var isCommand: Bool { method.contains("commandExecution") }
    private var isFile: Bool { method.contains("fileChange") }
    private var isPermission: Bool { method.contains("permissions") }
    private var supported: Bool { request["supported"].bool && params["computerUse"] == .null && (isInput || isCommand || isFile || isPermission) }
    private var submitted: Bool { chat.wasResponded(request) }
    private var busy: Bool { chat.isResponding(request) }
    private var editable: Bool { chat.canRespond && !submitted && !busy }
    private var title: String {
        isInput ? "Codex 需要你的回复" : isFile ? "允许修改文件？" : isCommand ? "允许运行命令？" : isPermission ? "允许本轮权限？" : "待确认请求"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: isInput ? "questionmark.bubble" : "hand.raised").font(.headline)
            if !params["reason"].string.isEmpty { Text(params["reason"].string).font(.subheadline) }
            if params["command"] != .null { detail(params["command"]) }
            if !params["cwd"].string.isEmpty { Label(params["cwd"].string, systemImage: "folder").font(.caption).textSelection(.enabled) }
            if !params["environmentId"].string.isEmpty { Text("执行环境：" + params["environmentId"].string).font(.caption).textSelection(.enabled) }
            if params["permissions"] != .null { detail(params["permissions"]) }
            if params["additionalPermissions"] != .null { DisclosureGroup("额外权限") { detail(params["additionalPermissions"]) } }
            if params["networkApprovalContext"] != .null { DisclosureGroup("网络访问范围") { detail(params["networkApprovalContext"]) } }
            if !params["grantRoot"].string.isEmpty { Text("请求写入目录：" + params["grantRoot"].string).font(.caption).textSelection(.enabled) }
            if !params["changes"].array.isEmpty {
                DisclosureGroup("查看文件变更（\(params["changes"].array.count)）") {
                    ForEach(Array(params["changes"].array.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(change["path"].string).font(.caption.bold()).textSelection(.enabled)
                            detail(change["diff"] == .null ? change : change["diff"])
                        }.padding(.vertical, 8)
                    }
                }.font(.subheadline)
            }
            if isInput && supported {
                ForEach(Array(params["questions"].array.enumerated()), id: \.offset) { _, question in
                    questionForm(question)
                }.disabled(!editable)
            }
            if !supported {
                Text("此类请求请在 Mac 端处理。").font(.subheadline).foregroundStyle(.secondary)
            } else if submitted {
                Text("已提交，等待处理…").font(.caption).foregroundStyle(.secondary)
            } else if !chat.canRespond {
                Text(chat.connected ? "当前网关未开放手机回应，请更新并重启 Mac 网关。" : "连接已断开，请恢复连接后处理。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack {
                    if isInput {
                        Button("提交回复") { submitAnswers() }.buttonStyle(.borderedProminent).tint(.primary)
                            .accessibilityIdentifier("native.request.submit." + id)
                    } else {
                        if allows("decline") {
                            Button("拒绝", role: .destructive) { decision("decline") }.buttonStyle(.bordered)
                                .accessibilityIdentifier("native.request.decline." + id)
                        }
                        if (isCommand || isFile) && allows("cancel") {
                            Button("取消") { decision("cancel") }.buttonStyle(.bordered)
                                .accessibilityIdentifier("native.request.cancel." + id)
                        }
                        Spacer(minLength: 4)
                        if allows("accept") {
                            Button(isPermission ? "本轮允许" : "本次允许") { decision("accept") }.buttonStyle(.borderedProminent).tint(.primary)
                                .accessibilityIdentifier("native.request.accept." + id)
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }.disabled(busy)
            }
            NativeNotice(text: draft.error, isError: true)
        }.padding(18).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain).accessibilityIdentifier("native.request." + id)
    }
    private func detail(_ value: JSONValue) -> some View {
        Text(value.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func questionForm(_ question: JSONValue) -> some View {
        let key = question["id"].string
        let answer = Binding(get: { draft.answers[key] ?? "" }, set: { draft.answers[key] = $0; draft.error = "" })
        return VStack(alignment: .leading, spacing: 10) {
            if !question["header"].string.isEmpty { Text(question["header"].string).font(.caption.bold()).foregroundStyle(.secondary) }
            Text(question["question"].string).font(.subheadline)
            ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                Button { NativeRequestKeyboard.dismiss(); answer.wrappedValue = option["label"].string } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: answer.wrappedValue == option["label"].string ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option["label"].string)
                            if !option["description"].string.isEmpty { Text(option["description"].string).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("native.request.option." + id + "." + key + "." + option["label"].string)
                    .accessibilityValue(answer.wrappedValue == option["label"].string ? "已选择" : "未选择")
            }
            NativeRequestInput(value: answer, placeholder: question["options"].array.isEmpty ? "输入你的回复" : "也可以填写其他回复",
                identifier: "native.request.answer." + id + "." + key,
                completionIdentifier: "native.request.keyboard.done." + id + "." + key, secret: question["isSecret"].bool)
        }
    }
    private func allows(_ decision: String) -> Bool { params["availableDecisions"] == .null || params["availableDecisions"].array.contains(string(decision)) }
    private func decision(_ value: String) { respond(json(["decision": string(value)])) }
    private func submitAnswers() {
        var fields: [String: JSONValue] = [:]
        for question in params["questions"].array {
            let key = question["id"].string, value = (draft.answers[question["id"].string] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { draft.error = "请回答所有问题"; return }
            guard value.unicodeScalars.count <= 20000 else { draft.error = "每个答案最多 20000 个字符"; return }
            fields[key] = .array([string(value)])
        }
        respond(json(["answers": json(fields)]))
    }
    private func respond(_ response: JSONValue) {
        guard editable else { return }
        NativeRequestKeyboard.dismiss()
        draft.error = ""
        Task { do { try await chat.respond(request, response: response) } catch { draft.error = error.localizedDescription } }
    }
}
