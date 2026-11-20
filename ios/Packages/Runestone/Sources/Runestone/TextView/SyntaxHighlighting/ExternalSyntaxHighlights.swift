import UIKit

/// A non-overlapping syntax color in UTF-16 document coordinates.
public struct SyntaxHighlight: Equatable {
    public let range: NSRange
    public let name: String

    public init(range: NSRange, name: String) {
        self.range = range
        self.name = name
    }
}

/// Draw precomputed highlights with the same native line layout as Tree-sitter.
final class ExternalSyntaxMode: PlainTextInternalLanguageMode {
    private(set) var highlights: [SyntaxHighlight] = []

    func update(_ highlights: [SyntaxHighlight]) {
        self.highlights = highlights
    }

    override func parse(_ text: NSString) {
        highlights = []
    }

    override func textDidChange(_ change: TextChange) -> LineChangeSet {
        // Old offsets are invalid once an edit changes the document.
        highlights = []
        return LineChangeSet()
    }

    override func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        ExternalLineHighlighter(mode: self)
    }
}

private final class ExternalLineHighlighter: LineSyntaxHighlighter {
    var theme: Theme = DefaultTheme.shared
    var canHighlight: Bool { !mode.highlights.isEmpty }
    private let mode: ExternalSyntaxMode

    init(mode: ExternalSyntaxMode) {
        self.mode = mode
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {
        let range = NSRange(input.byteRange)
        let highlights = mode.highlights
        var lower = 0
        var upper = highlights.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(highlights[middle].range) <= range.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        for highlight in highlights[lower...] {
            if highlight.range.location >= NSMaxRange(range) { break }
            let overlap = NSIntersectionRange(range, highlight.range)
            guard overlap.length > 0, let color = theme.textColor(for: highlight.name) else { continue }
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            input.attributedString.addAttribute(.foregroundColor, value: color, range: local)
        }
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        syntaxHighlight(input)
        completion(.success(.init(isSizingInvalid: false)))
    }

    func cancel() {}
}
