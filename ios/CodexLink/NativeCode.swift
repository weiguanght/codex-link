import SwiftUI
import Runestone
final class NativeCodeTheme: Runestone.Theme {
    let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var textColor: UIColor { .label }
    var gutterBackgroundColor: UIColor { .secondarySystemBackground }
    var gutterHairlineColor: UIColor { .separator }
    var lineNumberColor: UIColor { .secondaryLabel }
    var lineNumberFont: UIFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    var selectedLineBackgroundColor: UIColor { .tertiarySystemFill }
    var selectedLinesLineNumberColor: UIColor { .label }
    var selectedLinesGutterBackgroundColor: UIColor { .tertiarySystemFill }
    var invisibleCharactersColor: UIColor { .tertiaryLabel }
    var pageGuideHairlineColor: UIColor { .separator }
    var pageGuideBackgroundColor: UIColor { .clear }
    var markedTextBackgroundColor: UIColor { .systemBlue.withAlphaComponent(0.15) }
    func textColor(for name: String) -> UIColor? {
        let name = name.lowercased()
        if name == "diff.plus" { return .systemGreen }
        if name == "diff.minus" { return .systemRed }
        if name == "diff.delta" { return .systemOrange }
        if ["text.title", "text.uri", "text.reference"].contains(name) { return .systemBlue }
        if name == "text.literal" { return .systemGreen }
        if name.contains("comment") { return .secondaryLabel }
        if name.contains("keyword") || name.contains("operator") { return .systemPurple }
        if name.contains("string") || name.contains("character") || name == "escape" { return .systemGreen }
        if name.contains("number") || name.contains("constant") || name.contains("boolean") || name == "float" { return .systemOrange }
        if name.contains("function") || name.contains("method") { return .systemBlue }
        if name.contains("type") || name.contains("constructor") || name.contains("tag") || name == "namespace" { return .systemTeal }
        if name.contains("property") || name.contains("attribute") || name == "field" || name == "label" { return .systemIndigo }
        return nil
    }
    func fontTraits(for name: String) -> FontTraits {
        if name == "text.strong" || name == "text.title" { return .bold }
        if name == "text.emphasis" { return .italic }
        return []
    }
}

struct NativeCodeView: UIViewRepresentable {
    @Binding var text: String
    let language: String
    var editable = false
    var wrapsLines = true
    var lineNumbers = true
    var identifier = "native.code"
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Runestone.TextView {
        let view = Runestone.TextView()
        view.backgroundColor = .secondarySystemBackground
        view.editorDelegate = context.coordinator
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.contentInset = UIEdgeInsets(top: 10, left: 8, bottom: 14, right: 8)
        view.isFindInteractionEnabled = true
        view.lineHeightMultiplier = 1.3
        view.accessibilityIdentifier = identifier
        view.isAccessibilityElement = true
        view.accessibilityLabel = "代码预览"
        context.coordinator.configure(view, text: text, language: language)
        return view
    }
    func updateUIView(_ view: Runestone.TextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable && !context.coordinator.preparing; view.isSelectable = true
        view.accessibilityLabel = editable ? "代码编辑器" : "代码预览"
        view.accessibilityTraits = editable ? [.allowsDirectInteraction] : [.staticText]
        view.isLineWrappingEnabled = wrapsLines; view.showLineNumbers = lineNumbers
        view.isCodeFoldingEnabled = true
        if context.coordinator.hint != language || (context.coordinator.lastAppliedText != text && view.text != text && !context.coordinator.preparing) {
            context.coordinator.configure(view, text: text, language: language)
        }
    }
    static func dismantleUIView(_ view: Runestone.TextView, coordinator: Coordinator) { coordinator.generation += 1; coordinator.pendingHighlight?.cancel(); view.editorDelegate = nil }
    final class Coordinator: NSObject, TextViewDelegate {
        var parent: NativeCodeView
        var hint = ""
        var generation = 0
        var preparing = false
        var lastAppliedText = ""
        var pendingHighlight: Task<Void, Never>?
        init(_ parent: NativeCodeView) { self.parent = parent }
        func configure(_ view: Runestone.TextView, text: String, language: String) {
            hint = language; generation += 1; let token = generation; preparing = true; lastAppliedText = text
            view.isEditable = false
            pendingHighlight?.cancel()
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                let theme = NativeCodeTheme()
                let state: TextViewState
                if let grammar = NativeCodeLanguages.language(language) { state = TextViewState(text: text, theme: theme, language: grammar, languageProvider: NativeCodeLanguageProvider()) }
                else if let tokenizer = NativeCodeLanguages.tokenizer(language) {
                    let highlights = NativeLexicalSyntax.highlights(text, language: tokenizer)
                    state = TextViewState(text: text, theme: theme, syntaxHighlights: highlights)
                } else { state = TextViewState(text: text, theme: theme) }
                DispatchQueue.main.async {
                    guard let self, let view, self.generation == token else { return }
                    view.setState(state)
                    view.accessibilityValue = text
                    if let endings = state.detectedLineEndings { view.lineEndings = endings }
                    self.preparing = false; view.isEditable = self.parent.editable
                    // A streamed update may have arrived while this state parsed.
                    if self.parent.text != text { self.configure(view, text: self.parent.text, language: self.parent.language) }
                }
            }
        }
        func textViewDidChange(_ view: Runestone.TextView) {
            guard !preparing, parent.editable else { return }
            let editedText = view.text
            lastAppliedText = editedText
            view.accessibilityValue = editedText
            parent.text = editedText
            guard let tokenizer = NativeCodeLanguages.tokenizer(hint) else { return }
            pendingHighlight?.cancel()
            let document = generation
            pendingHighlight = Task { @MainActor [weak self, weak view] in
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                let worker = Task.detached(priority: .userInitiated) {
                    NativeLexicalSyntax.highlights(editedText, language: tokenizer)
                }
                let highlights = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, let view, self.generation == document else { return }
                view.updateSyntaxHighlights(highlights)
            }
        }
    }
}

struct NativeCodeBlock: View {
    let text: String
    let language: String
    @State private var expanded = false
    private var height: CGFloat { CGFloat(min(14, max(2, text.components(separatedBy: "\n").count))) * 20 + 26 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeCodeView(text: .constant(text), language: language, lineNumbers: false).frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Button("展开代码", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }.font(.caption)
        }.sheet(isPresented: $expanded) {
            NavigationStack {
                NativeCodeView(text: .constant(text), language: language)
                    .navigationTitle(NativeCodeLanguages.name(language)).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { expanded = false } } }
            }
        }
    }
}

/// A selectable, naturally sized code block without an editor gutter or nested sheet.
/// Parsing stays off the main actor, including for streamed command updates.
enum NativeSyntaxHighlight {
    static func native(_ text: String, language: String, theme: NativeCodeTheme = NativeCodeTheme()) -> NSAttributedString {
        if let tokenizer = NativeCodeLanguages.tokenizer(language) {
            return NativeLexicalSyntax.attributed(text, language: tokenizer, theme: theme)
        }
        guard !text.isEmpty, let grammar = NativeCodeLanguages.language(language) else {
            return NSAttributedString(string: text)
        }
        let highlighter = Runestone.StringSyntaxHighlighter(theme: theme, language: grammar, languageProvider: NativeCodeLanguageProvider())
        return highlighter.syntaxHighlight(text)
    }

    static func text(_ text: String, language: String) -> AttributedString {
        (try? AttributedString(native(text, language: language), including: \.uiKit)) ?? AttributedString(text)
    }
}
struct NativeSyntaxText: View {
    let text: String
    let language: String
    var wrapsLines = true
    var singleLine = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: AttributedString?
    @State private var appliedText = ""
    private struct Request: Hashable { let text: String; let language: String; let dark: Bool }
    var body: some View {
        Group {
            if singleLine {
                code.lineLimit(1).truncationMode(.tail)
            } else if wrapsLines {
                code.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) { code.fixedSize(horizontal: true, vertical: true) }
            }
        }
        .task(id: Request(text: text, language: language, dark: colorScheme == .dark)) {
            let parsed = await Task.detached(priority: .userInitiated) { NativeSyntaxHighlight.text(text, language: language) }.value
            if !Task.isCancelled { appliedText = text; highlighted = parsed }
        }
    }
    private var code: some View {
        Text(appliedText == text ? highlighted ?? AttributedString(text) : AttributedString(text)).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
    }
}
