import JavaScriptCore
import Runestone
import UIKit

enum NativeLexicalSyntax {
    private static let queue = DispatchQueue(label: "codex-link.syntax", qos: .userInitiated)
    // All JSContext access is serialized by the syntax queue. Source text is
    // passed as an argument to the bundled tokenizer.
    private static let tokenizer: JSValue? = {
        guard let asset = Bundle.main.url(forResource: "SyntaxHighlighter", withExtension: "js", subdirectory: "SyntaxAssets"),
              let script = try? String(contentsOf: asset, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context.objectForKeyedSubscript("codexLinkSyntaxRanges")
    }()

    static func highlights(_ text: String, language: String) -> [SyntaxHighlight] {
        let length = text.utf16.count
        // Whole-file tokenization handles multiline comments and strings.
        // Large generated files remain readable without re-tokenizing on edits.
        guard (1...256 * 1024).contains(length) else { return [] }
        return queue.sync {
            guard !Task.isCancelled, let tokenizer, !tokenizer.isUndefined,
                  let rows = tokenizer.call(withArguments: [text, language])?.toArray() as? [[Any]] else { return [] }
            var end = 0
            return rows.compactMap { row in
                guard row.count == 3,
                      let offset = row[0] as? Int, let count = row[1] as? Int, let name = row[2] as? String,
                      offset >= end, offset <= length, count > 0, count <= length - offset else { return nil }
                end = offset + count
                return SyntaxHighlight(range: NSRange(location: offset, length: count), name: name)
            }
        }
    }

    static func attributed(_ text: String, language: String, theme: NativeCodeTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        for highlight in highlights(text, language: language) {
            if let color = theme.textColor(for: highlight.name) {
                result.addAttribute(.foregroundColor, value: color, range: highlight.range)
            }
        }
        return result
    }
}
