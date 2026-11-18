import SwiftUI
import UIKit

enum NativeClipboard {
    static func copy(_ value: String) {
        UIPasteboard.general.string = value
        confirmCopy()
    }
    static func confirmCopy() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        NativeClipboardState.shared.didCopy()
    }
}

final class NativeClipboardState: ObservableObject {
    static let shared = NativeClipboardState()
    @Published private(set) var generation = 0
    func didCopy() { generation &+= 1 }
}

struct NativeCopyFeedback: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(red: 0.08, green: 0.22, blue: 0.20))
                .frame(width: 28, height: 28)
                .background(Color(red: 0.12, green: 0.72, blue: 0.57), in: Circle())
            Text("已复制").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: 150, height: 58)
        .background(Color(red: 0.18, green: 0.18, blue: 0.18).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已复制")
        .accessibilityIdentifier("native.copy.feedback")
    }
}

struct NativeCopyFeedbackModifier: ViewModifier {
    @ObservedObject private var clipboard = NativeClipboardState.shared
    @State private var visible = false
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.overlay {
            if visible { NativeCopyFeedback().transition(.scale(scale: 0.96).combined(with: .opacity)).allowsHitTesting(false) }
        }
        .onChange(of: clipboard.generation) { _ in
            let next = UUID(); token = next
            withAnimation(.easeOut(duration: 0.16)) { visible = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard token == next else { return }
                withAnimation(.easeIn(duration: 0.16)) { visible = false }
            }
        }
    }
}

extension View {
    func nativeCopyFeedback() -> some View { modifier(NativeCopyFeedbackModifier()) }
}

extension Color {
    static let linkSurface = Color(uiColor: .secondarySystemBackground)
    static let linkCanvas = Color(uiColor: .systemBackground)
}
struct NativeIconButton: View {
    let symbol: String
    let label: String
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(filled ? Color.linkCanvas : Color.primary)
                .background(filled ? Color.primary : Color.clear, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
/// Shared row metrics for the chat dropdown and its native session menu label.
struct NativeDropdownLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: symbol).frame(width: 20)
        }
        .font(.system(size: 16))
        .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle())
    }
}
struct NativeDropdownButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.35))
            .background(configuration.isPressed ? Color(uiColor: .tertiarySystemFill) : Color.clear)
    }
}
struct NativeNotice: View {
    let text: String
    var isError = false
    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .font(.footnote).foregroundStyle(isError ? Color.red : Color.secondary)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
struct NativeChatMarkdown: View {
    let text: String
    @AppStorage("native.diffLineWrapping") private var diffLineWrapping = true
    @State private var selectSource = false
    var body: some View {
        let blocks = NativeMarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                if block.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(block.language.isEmpty ? "代码" : block.language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { NativeClipboard.copy(block.content) } label: { Label("复制", systemImage: "doc.on.doc").font(.caption) }.buttonStyle(.plain)
                        }
                        if ["diff", "patch"].contains(block.language.trimmingCharacters(in: .whitespaces).lowercased()) {
                            NativeDiff(content: block.content, wrapsLines: diffLineWrapping)
                        } else {
                            NativeCodeBlock(text: block.content, language: block.language)
                        }
                    }.padding(14).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 16))
                } else if let table = block.table {
                    NativeMarkdownTableView(table: table)
                } else if !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NativeSelectableText(text: block.content, accessibilityIdentifier: "native.message.selectable")
                }
            }
            if blocks.count > 1 && blocks.contains(where: { $0.code || $0.table != nil }) {
                Button { selectSource = true } label: {
                    Label("跨区块选择文本", systemImage: "text.cursor").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).tint(.blue)
        .sheet(isPresented: $selectSource) {
            NavigationStack {
                ScrollView {
                    NativeSelectableText(text: text, accessibilityIdentifier: "native.message.selectionSource", plain: true)
                        .padding(20)
                }
                .navigationTitle("选择 Markdown 文本").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selectSource = false } } }
            }
        }
    }
}

enum NativeMessageLinks {
    // Encode local destinations before Foundation parses Markdown: unescaped
    // spaces and Unicode paths otherwise lose their link attributes. Leave
    // inline code untouched, and resolve downloads only against chat.files.
    static func attributed(_ value: String) -> AttributedString {
        let pattern = #"(`+).*?\1|(!?\[[^\]\n]*\])\((?:<([^>\n]+)>|([^\n)]+))\)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let source = value as NSString
        var markdown = value
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
            guard match.range(at: 2).location != NSNotFound else { continue }
            let targetRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 4)
            let reference = source.substring(with: targetRange).trimmingCharacters(in: .whitespaces)
            guard isLocal(reference), let url = url(reference: reference), let range = Range(match.range, in: markdown) else { continue }
            markdown.replaceSubrange(range, with: source.substring(with: match.range(at: 2)) + "(" + url.absoluteString + ")")
        }
        var result = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        for run in result.runs where run.link != nil {
            result[run.range].foregroundColor = .blue
            result[run.range].underlineStyle = .single
        }
        return result
    }
    static func isLocal(_ reference: String) -> Bool { reference.hasPrefix("/") || reference.lowercased().hasPrefix("file://") }
    static func url(reference: String) -> URL? {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = reference.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: "codex-link-file://open?reference=" + encoded)
    }
    static func reference(_ url: URL) -> String? {
        if url.scheme == "codex-link-file", url.host == "open" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "reference" }?.value
        }
        return isLocal(url.absoluteString) ? url.absoluteString : nil
    }
    static func normalized(_ reference: String) -> String {
        if reference.lowercased().hasPrefix("file://"), let url = URL(string: reference) { return url.path }
        return reference.removingPercentEncoding ?? reference
    }
    static func file(for url: URL, files: [JSONValue]) -> JSONValue? {
        guard let target = reference(url) else { return nil }
        return files.first { normalized($0["reference"].string) == normalized(target) }
    }
}
struct ShareView: UIViewControllerRepresentable {
    let file: URL
    var cleanupOnDismiss = true
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "native.file.share"
        controller.completionWithItemsHandler = { _, _, _, _ in
            if cleanupOnDismiss { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct ShareFile: Identifiable { let url: URL; var id: String { url.path } }
struct NativeTextDocument: View {
    let title: String
    let text: String
    var body: some View { ScrollView { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
}

// String-title convenience keeps the native controls available on iOS 16.
extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}
