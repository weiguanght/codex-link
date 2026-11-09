import SwiftUI
import UIKit

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
struct NativeSelectableText: UIViewRepresentable {
    let value: AttributedString
    var accessibilityIdentifier: String? = nil
    var fontSize: CGFloat = 16
    var textColor: UIColor = .label
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> SelectableMessageTextView {
        let view = SelectableMessageTextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = textColor
        let styled = NSMutableAttributedString(value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        view.attributedText = styled
        view.isAccessibilityElement = true
        let plainText = String(value.characters)
        view.accessibilityLabel = plainText
        view.delegate = context.coordinator
        view.accessibilityIdentifier = accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: SelectableMessageTextView, context: Context) {
        context.coordinator.openURL = openURL
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = textColor
        view.accessibilityIdentifier = accessibilityIdentifier
        let plainText = String(value.characters)
        let textChanged = view.accessibilityLabel != plainText
        view.accessibilityLabel = plainText
        let value = NSAttributedString(value)
        if textChanged {
            let selected = view.selectedRange
            let styled = NSMutableAttributedString(attributedString: value)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
            view.attributedText = styled
            view.selectedRange = NSRange(location: min(selected.location, value.length), length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableMessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            openURL(URL)
            return false
        }
    }
}

final class SelectableMessageTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copy(_:))
    }
}

struct NativeChatMarkdown: View {
    let text: String
    @AppStorage("native.diffLineWrapping") private var diffLineWrapping = true
    private var blocks: [NativeMarkdownBlock] { NativeMarkdownBlock.parse(text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                if block.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(block.language.isEmpty ? "代码" : block.language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = block.content } label: { Label("复制", systemImage: "doc.on.doc").font(.caption) }.buttonStyle(.plain)
                        }
                        if ["diff", "patch"].contains(block.language.trimmingCharacters(in: .whitespaces).lowercased()) {
                            NativeDiff(content: block.content, wrapsLines: diffLineWrapping)
                        } else {
                            NativeCodeBlock(text: block.content, language: block.language)
                        }
                    }.padding(14).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 16))
                } else if let table = block.table {
                    NativeMarkdownTableView(table: table)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(block.content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            markdownLine(line)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).tint(.blue)
    }
    @ViewBuilder private func markdownLine(_ line: String) -> some View {
        let heading = line.prefix(while: { $0 == "#" }).count
        if line == "---" || line == "***" { Divider().padding(.vertical, 8) }
        else if heading > 0 && heading <= 6 && line.dropFirst(heading).hasPrefix(" ") {
            NativeSelectableText(value: inline(String(line.dropFirst(heading + 1))), accessibilityIdentifier: "native.message.selectable",
                                 fontSize: heading <= 2 ? 20 : 17)
                .padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) { Text("•"); NativeSelectableText(value: inline(String(line.dropFirst(2))), accessibilityIdentifier: "native.message.selectable").frame(maxWidth: .infinity, alignment: .leading) }
        } else if line.hasPrefix("> ") {
            HStack(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 3); NativeSelectableText(value: inline(String(line.dropFirst(2))), accessibilityIdentifier: "native.message.selectable", textColor: .secondaryLabel) }.fixedSize(horizontal: false, vertical: true)
        } else if line.isEmpty { Color.clear.frame(height: 5) }
        else { NativeSelectableText(value: inline(line), accessibilityIdentifier: "native.message.selectable").frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func inline(_ value: String) -> AttributedString { NativeMessageLinks.attributed(value) }
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
