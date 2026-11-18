import SwiftUI

struct NativeTurnProcessState: Equatable {
    let expanded: Bool
    let loading: Bool
    let hasMore: Bool
    let error: String
}

/// Unchanged messages do not reparse Markdown when composer/layout state changes.
struct NativeChatRow: View, Equatable {
    let sessionIdentity: String
    let cursor: String
    let row: NativeRow
    let text: String
    let stats: NativeDiffStats?
    let readOnly: Bool
    let hasMore: Bool
    let processState: NativeTurnProcessState?
    let insideProcess: Bool
    let onTool: () -> Void
    let onAttachment: (JSONValue) -> Void
    let onCopy: (String) -> Void
    let onExpand: () -> Void
    let onMessageAction: () -> Void
    let onLoadStats: () async -> Void
    let onToggleProcess: () -> Void
    let onLoadProcess: () async -> Void
    static func == (left: Self, right: Self) -> Bool {
        left.sessionIdentity == right.sessionIdentity && left.cursor == right.cursor && left.row == right.row && left.text == right.text &&
        left.stats == right.stats && left.readOnly == right.readOnly && left.hasMore == right.hasMore &&
        left.processState == right.processState && left.insideProcess == right.insideProcess
    }
    var body: some View {
        #if LINK_SMOKE
        let _ = NativeChatRenderMetrics.rowBodies += 1
        #endif
        Group {
            if let processState { processHeader(processState) }
            else if row.isProcess { NativeToolRow(row: row, text: text, stats: stats) { onTool() } }
            else { message }
        }
        .padding(.horizontal, insideProcess ? 12 : 0)
        .padding(.vertical, insideProcess ? 8 : 0)
        .background(insideProcess ? Color.linkSurface : Color.clear)
        .overlay(alignment: .leading) {
            if insideProcess { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2) }
        }
    }
    private var message: some View {
        VStack(alignment: row.role == "user" ? .trailing : .leading, spacing: 10) {
            if row.role == "user" {
                NativeUserMessage(text: text, onCopy: { onCopy(text) }).padding(.leading, 30)
            } else if row.role == "error" { NativeNotice(text: text, isError: true) }
            else { NativeChatMarkdown(text: text).font(.system(size: 16)).lineSpacing(5) }
            if let attachments = row.attachments {
                NativeFileListLayout {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                        Button { onAttachment(attachment) } label: {
                            Label(attachment["name"].string.isEmpty ? "附件" : attachment["name"].string, systemImage: "paperclip")
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }
            }
            if hasMore { Button("继续加载正文") { onExpand() }.font(.caption) }
            if row.editable == true && !readOnly {
                Button { onMessageAction() } label: { Label("编辑消息", systemImage: "pencil").font(.caption) }.foregroundStyle(.secondary)
            }
            if row.role == "assistant" {
                HStack(spacing: 20) {
                    Button { onCopy(text) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制回复")
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享回复")
                    if row.forkable == true && !readOnly && !insideProcess { Button { onMessageAction() } label: { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("从此处分支") }
                }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.role == "user" ? .trailing : .leading)
    }

    private func processHeader(_ state: NativeTurnProcessState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggleProcess) {
                HStack(spacing: 8) {
                    if row.turnRunning, let startedAt = row.startedAtMs {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.elapsed(Int(context.date.timeIntervalSince1970 * 1000) - startedAt))
                        }
                    } else { Text(Self.elapsed(row.durationMs)) }
                    Image(systemName: state.expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("native.turn.process." + (row.turnId ?? row.key))
                .accessibilityValue(state.expanded ? "展开" : "收起")
            if state.expanded {
                if state.loading { ProgressView().controlSize(.small).padding(.bottom, 8) }
                if !state.error.isEmpty {
                    Text(state.error).font(.caption).foregroundStyle(.red)
                    Button("重试加载") { Task { await onLoadProcess() } }.font(.caption)
                } else if state.hasMore && !state.loading {
                    Button("加载更多过程") { Task { await onLoadProcess() } }.font(.caption).padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, state.expanded ? 12 : 0)
        .background(state.expanded ? Color.linkSurface : Color.clear)
    }

    private static func elapsed(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "用时未知" }
        let seconds = max(0, milliseconds / 1000)
        return "用时 \(seconds / 60)分\(String(format: "%02d", seconds % 60))秒"
    }
}

private struct NativeUserMessage: View {
    let text: String
    let onCopy: () -> Void
    @State private var fullHeight: CGFloat = 0
    @State private var expanded = false
    private var isLong: Bool { fullHeight > 122 }
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: 16)).lineSpacing(5).lineLimit(expanded ? nil : 5)
                .accessibilityIdentifier("native.message.user.text")
                .overlay(alignment: .topLeading) {
                    Text(text).font(.system(size: 16)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true).hidden().background(GeometryReader { proxy in
                            Color.clear.preference(key: NativeUserTextHeight.self, value: proxy.size.height)
                        }).accessibilityHidden(true)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 24))
            HStack(spacing: 14) {
                if isLong {
                    Button(expanded ? "收起" : "展开") { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                        .accessibilityIdentifier("native.message.user.expand")
                }
                Button(action: onCopy) { Image(systemName: "doc.on.doc").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .accessibilityLabel("复制消息").accessibilityIdentifier("native.message.copy.user")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .onPreferenceChange(NativeUserTextHeight.self) { value in
            if abs(fullHeight - value) > 1 { fullHeight = value }
        }
    }
}

private struct NativeUserTextHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
