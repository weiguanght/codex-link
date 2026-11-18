import SwiftUI
import UIKit

/// Only this view observes keystrokes. The transcript observes ChatModel instead.
struct NativeChatComposer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var draft: NativeComposerDraft
    let focus: FocusState<Bool>.Binding
    let contextUsage: JSONValue
    let uploading: Bool
    let onPhoto: () -> Void
    let onCamera: () -> Void
    let onFile: () -> Void
    let onSend: () -> Void
    let onChooseMode: () -> Void
    let onError: (String) -> Void
    var body: some View {
        VStack(spacing: 9) {
            NativeNotice(text: draft.value.recoveryNotice)
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
                if !draft.value.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack {
                        ForEach(draft.value.attachments) { file in HStack(spacing: 8) { Image(systemName: "doc"); Text(file.name).lineLimit(1); Button { draft.value.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") } }.font(.caption).padding(10).background(Color.linkSurface, in: Capsule()) }
                    } }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("选择照片", systemImage: "photo") { onPhoto() }
                        Button("拍照", systemImage: "camera") { onCamera() }.disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        Divider()
                        Button("选择文件", systemImage: "doc") { onFile() }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("添加附件").accessibilityIdentifier("native.attachment.menu").disabled(uploading || chat.busy)
                    TextField("", text: $draft.value.text, prompt: Text(NativeContextUsage(contextUsage)?.placeholder ?? "上下文用量暂无数据").foregroundColor(Color(uiColor: .placeholderText)), axis: .vertical).lineLimit(1...7).font(.system(size: 16)).focused(focus).padding(.vertical, 12).accessibilityIdentifier("native.composer")
                    if uploading || chat.busy { ProgressView().frame(width: 44, height: 44) }
                    else if chat.running && draft.value.text.isEmpty && draft.value.attachments.isEmpty {
                        NativeIconButton(symbol: "stop.fill", label: "停止任务", filled: true) { perform { try await chat.stop() } }.disabled(!chat.connected)
                    } else {
                        NativeSendButton(enabled: chat.canSend, onSend: { onSend() }, onChooseMode: { focus.wrappedValue = false; onChooseMode() })
                            .frame(width: 44, height: 44)
                    }
                }.padding(7).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 29))

            }
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { onError(error.localizedDescription) } }
    }
}

struct NativeSendSettings: View {
    @ObservedObject var draft: NativeComposerDraft
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.followUpBehavior") private var defaultSendMode = "send"
    var body: some View {
        NavigationStack {
            Form {
                Picker("工作模式", selection: $draft.value.workMode) { Text("普通").tag("default"); Text("计划").tag("plan") }
                Picker("默认发送方式", selection: $draft.value.sendMode) {
                    Text("发送新消息").tag("send"); Text("完成后发送").tag("queue"); Text("补充当前任务").tag("steer")
                }.accessibilityIdentifier("native.send.defaultMode")
                Text("任务执行时使用所选方式；任务结束后直接发送新消息。长按发送按钮可仅为本次消息选择方式。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("消息发送设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onChange(of: draft.value.sendMode) { defaultSendMode = $0 }
        }
    }
}

struct NativeDraftSkills: View {
    @ObservedObject var draft: NativeComposerDraft
    let skills: [JSONValue]
    var body: some View {
        ForEach(Array(skills.enumerated()), id: \.offset) { _, row in
            Toggle(row["name"].string, isOn: Binding(get: { draft.value.skills.contains(row["id"].string) }, set: { enabled in
                if enabled && draft.value.skills.count < 8 { draft.value.skills.append(row["id"].string) }
                else { draft.value.skills.removeAll { $0 == row["id"].string } }
            }))
        }
    }
}
