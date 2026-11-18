import SwiftUI

/// Unchanged messages do not reparse Markdown when composer/layout state changes.
struct NativeChatRow: View, Equatable {
    let sessionIdentity: String
    let cursor: String
    let row: NativeRow
    let text: String
    let stats: NativeDiffStats?
    let readOnly: Bool
    let hasMore: Bool
    let onTool: () -> Void
    let onAttachment: (JSONValue) -> Void
    let onCopy: (String) -> Void
    let onExpand: () -> Void
    let onMessageAction: () -> Void
    let onLoadStats: () async -> Void
    static func == (left: Self, right: Self) -> Bool {
        left.sessionIdentity == right.sessionIdentity && left.cursor == right.cursor && left.row == right.row && left.text == right.text &&
        left.stats == right.stats && left.readOnly == right.readOnly && left.hasMore == right.hasMore
    }
    var body: some View {
        #if LINK_SMOKE
        let _ = NativeChatRenderMetrics.rowBodies += 1
        #endif
        if row.isProcess { NativeToolRow(row: row, text: text, stats: stats) { onTool() } }
        else { message }
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
                    if row.forkable == true && !readOnly { Button { onMessageAction() } label: { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("从此处分支") }
                }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.role == "user" ? .trailing : .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
