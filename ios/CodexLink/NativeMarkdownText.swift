import SwiftUI
import UIKit

enum NativeMarkdownMath {
    struct Formula {
        let source: String
        let latex: String
        let display: Bool
    }

    // Skip code spans, Markdown link destinations, and escaped delimiters.
    private static let excluded = try! NSRegularExpression(pattern:
        #"(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)|\]\((?:<[^>\n]*>|[^)\n]*)\)|\\\$"#)
    private static let spans = try! NSRegularExpression(pattern:
        #"(?m:^[ \t]*)(?:\$\$([\s\S]+?)(?<!\\)\$\$|\\\[([\s\S]+?)(?<!\\)\\\])[ \t]*(?=\n|$)|\\\(([^\n]+?)(?<!\\)\\\)|(?<!\$)\$(?![\s$])([^\n$]*?[^\s\\$\n])\$(?![\d$])"#)

    static func mayContainMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
    }

    static func protect(_ text: String) -> (text: String, formulas: [String: Formula]) {
        guard mayContainMath(text) else { return (text, [:]) }
        var result = text
        var formulas: [String: Formula] = [:]
        let source = text as NSString
        let prefix = "\u{E000}" + UUID().uuidString
        let fullRange = NSRange(location: 0, length: source.length)
        let excludedRanges = excluded.matches(in: text, range: fullRange).map(\.range)
        for match in spans.matches(in: text, range: fullRange).reversed() {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let group = (1...4).first(where: { match.range(at: $0).location != NSNotFound }),
                  let range = Range(match.range, in: result) else { continue }
            let latex = source.substring(with: match.range(at: group)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { continue }
            let marker = prefix + "\(formulas.count)\u{E001}"
            formulas[marker] = Formula(source: source.substring(with: match.range).trimmingCharacters(in: .whitespaces), latex: latex, display: group <= 2)
            result.replaceSubrange(range, with: marker)
        }
        return (result, formulas)
    }
}

enum NativeMarkdownText {
    static func styled(_ text: String, traits: UITraitCollection, cell: Bool = false, bold: Bool = false,
                       alignment: NativeMarkdownTable.ColumnAlignment = .leading,
                       availableWidth: CGFloat = UIScreen.main.bounds.width - 32) -> NSAttributedString {
        let protected = NativeMarkdownMath.protect(text)
        let result = NSMutableAttributedString(string: "")
        let lines = protected.text.components(separatedBy: "\n")
        let bodySize = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: traits)
        for (index, source) in lines.enumerated() {
            var line = source
            var size = bodySize
            var weight: UIFont.Weight = bold ? .semibold : .regular
            var color = UIColor.label
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = cell ? 0 : 5
            if cell {
                switch alignment {
                case .leading: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }
            }

            if let formula = protected.formulas[line], formula.display {
                paragraph.alignment = .center
            } else if !cell {
                let heading = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(heading), line.dropFirst(heading).hasPrefix(" ") {
                    line = String(line.dropFirst(heading + 1))
                    size += heading <= 2 ? 4 : 1
                    weight = .semibold
                    paragraph.paragraphSpacingBefore = 5
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                    line = "•\t" + line.dropFirst(2)
                    paragraph.headIndent = size
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: size)]
                } else if line.hasPrefix("> ") {
                    line = "│  " + line.dropFirst(2)
                    color = .secondaryLabel
                    paragraph.headIndent = 12
                } else if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) {
                    line = "────────"
                    color = .tertiaryLabel
                }
            }
            let rendered = NSMutableAttributedString(string: "")
            let inline = NativeMessageLinks.attributed(line)
            for run in inline.runs {
                let intent = run.inlinePresentationIntent
                var font = intent?.contains(.code) == true
                    ? UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
                    : UIFont.systemFont(ofSize: size, weight: intent?.contains(.stronglyEmphasized) == true ? .semibold : weight)
                if intent?.contains(.emphasized) == true,
                   let italic = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                    font = UIFont(descriptor: italic, size: font.pointSize)
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                rendered.append(NSAttributedString(string: String(inline.characters[run.range]), attributes: attributes))
            }
            for (marker, formula) in protected.formulas where line.contains(marker) {
                let range = (rendered.string as NSString).range(of: marker)
                guard range.location != NSNotFound else { continue }
                let replacement: NSAttributedString
                if let attachment = FormulaAttachment(formula, size: size,
                                                       color: color.resolvedColor(with: traits),
                                                       width: availableWidth, displayScale: traits.displayScale) {
                    replacement = NSAttributedString(attachment: attachment)
                } else {
                    replacement = NSAttributedString(string: formula.source, attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color])
                }
                rendered.replaceCharacters(in: range, with: replacement)
            }
            if index < lines.count - 1 {
                let breakSize = line.isEmpty ? bodySize * 0.5 : size
                rendered.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: breakSize)]))
            }
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: rendered.length))
            result.append(rendered)
        }
        return result
    }

    static func copiedText(_ value: NSAttributedString, range: NSRange) -> String {
        let selected = value.attributedSubstring(from: range)
        let result = NSMutableString(string: selected.string)
        selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length), options: .reverse) { attachment, range, _ in
            if let formula = attachment as? FormulaAttachment { result.replaceCharacters(in: range, with: formula.source) }
        }
        return result as String
    }
}

private final class FormulaAttachment: NSTextAttachment {
    let source: String

    init?(_ formula: NativeMarkdownMath.Formula, size: CGFloat, color: UIColor, width: CGFloat, displayScale: CGFloat) {
        guard let rendered = NativeLatexRenderer.render(formula.latex, widthLimit: width,
                                                         fontSize: size, textColor: color,
                                                         display: formula.display, displayScale: displayScale)
        else { return nil }
        source = formula.source
        super.init(data: nil, ofType: nil)
        image = rendered.image
        bounds = CGRect(x: 0, y: -rendered.descent,
                        width: rendered.image.size.width, height: rendered.image.size.height)
    }

    required init?(coder: NSCoder) { nil }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex: Int) -> CGRect {
        let width = textContainer?.size.width ?? lineFrag.width
        guard width > 0, bounds.width > width else { return bounds }
        let scale = width / bounds.width
        return CGRect(x: 0, y: bounds.minY * scale, width: width, height: bounds.height * scale)
    }
}

struct NativeSelectableText: UIViewRepresentable {
    let text: String
    var accessibilityIdentifier: String? = nil
    var cell = false
    var bold = false
    var alignment: NativeMarkdownTable.ColumnAlignment = .leading
    var plain = false
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> SelectableMessageTextView {
        #if LINK_SMOKE
        NativeChatRenderMetrics.textCreations += 1
        #endif
        let view = SelectableMessageTextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.isAccessibilityElement = true
        view.linkTextAttributes = [.foregroundColor: UIColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = accessibilityIdentifier
        return view
    }

    func updateUIView(_ view: SelectableMessageTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openURL = openURL
        view.accessibilityIdentifier = accessibilityIdentifier
        guard coordinator.text != text || coordinator.scheme != colorScheme || coordinator.typeSize != typeSize else { return }
        coordinator.text = text
        coordinator.scheme = colorScheme
        coordinator.typeSize = typeSize
        coordinator.measured.removeAll(keepingCapacity: true)
        let selected = view.selectedRange
        let traits = UITraitCollection(traitsFrom: [
            view.traitCollection, UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        ])
        let availableWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width - 32
        let value = plain ? NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits), .foregroundColor: UIColor.label]) :
            NativeMarkdownText.styled(text, traits: traits, cell: cell, bold: bold,
                                      alignment: alignment, availableWidth: availableWidth)
        view.attributedText = value
        view.accessibilityLabel = NativeMarkdownText.copiedText(value, range: NSRange(location: 0, length: value.length))
        if selected.location != NSNotFound, NSMaxRange(selected) <= value.length { view.selectedRange = selected }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableMessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        if let size = context.coordinator.measured[width] { return size }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: fitted.height)
        context.coordinator.measured[width] = size
        #if LINK_SMOKE
        NativeChatRenderMetrics.textMeasurements += 1
        #endif
        return size
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        var text: String?
        var scheme: ColorScheme?
        var typeSize: DynamicTypeSize?
        var measured: [CGFloat: CGSize] = [:]
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            if interaction == .invokeDefaultAction { openURL(url) }
            return false
        }
    }
}

final class SelectableMessageTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // TextKit 1 sizes the formula attachment against the current column width.
        _ = layoutManager
        isEditable = false
        isSelectable = true
    }

    required init?(coder: NSCoder) { nil }

    override func copy(_ sender: Any?) {
        guard let value = attributedText, selectedRange.length > 0, NSMaxRange(selectedRange) <= value.length else { return }
        NativeClipboard.copy(NativeMarkdownText.copiedText(value, range: selectedRange))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return selectedRange.length > 0
        case #selector(select(_:)), #selector(selectAll(_:)):
            return super.canPerformAction(action, withSender: sender)
        default: return false
        }
    }
}
