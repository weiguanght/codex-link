import SwiftUI

/// Text-only unified-diff presentation. No Markdown/HTML interpretation of paths or patch lines.
struct NativeDiff: View {
    let content: String
    let wrapsLines: Bool
    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }
    private var annotated: Text {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        // Large tool outputs retain all text without thousands of Text concatenations.
        if lines.count > 2_000 { return Text(content) }
        return lines.enumerated().reduce(Text("")) { text, row in
            let separator = row.offset == 0 ? "" : "\n"
            return text + Text(separator + String(row.element)).foregroundColor(color(row.element))
        }
    }
    var body: some View {
        Group {
            if wrapsLines {
                annotated.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) { annotated.fixedSize(horizontal: true, vertical: false) }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .accessibilityLabel("代码差异")
    }
}
