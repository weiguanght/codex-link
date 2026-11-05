import SwiftUI

struct NativeToolPresentation {
    let kind: String
    let input: String
    let output: String
    let status: String
    let symbol: String
    let failed: Bool
    init(row: NativeRow, text: String) {
        kind = row.kind ?? "tool"
        if let length = row.inputLength {
            let scalars = text.unicodeScalars
            let end = scalars.index(scalars.startIndex, offsetBy: max(0, length), limitedBy: scalars.endIndex) ?? scalars.endIndex
            input = String(scalars[..<end])
            let rest = String(scalars[end...]); output = rest.hasPrefix("\n\n") ? String(rest.dropFirst(2)) : rest
        } else if ["commandExecution", "mcpToolCall", "dynamicToolCall"].contains(kind), let split = text.range(of: "\n\n") {
            input = String(text[..<split.lowerBound]); output = String(text[split.upperBound...])
        } else { input = text; output = "" }
        failed = row.status == "failed" || row.status == "error" || row.exitCode.map { $0 != 0 } == true
        if failed { status = row.exitCode.map { "失败 · exit \($0)" } ?? "失败"; symbol = "xmark.circle.fill" }
        else {
            switch row.status {
            case "inProgress", "in_progress", "running": status = "执行中"; symbol = "clock"
            case "completed", "success": status = "已完成"; symbol = "checkmark.circle.fill"
            case "interrupted", "cancelled": status = "已中断"; symbol = "stop.circle"
            default: status = ""; symbol = "circle.dotted"
            }
        }
    }
    var language: String { kind == "commandExecution" ? "bash" : ["mcpToolCall", "dynamicToolCall"].contains(kind) ? "json" : "text" }
    var icon: String { kind == "commandExecution" ? "terminal" : kind == "fileChange" ? "doc.badge.gearshape" : "wrench.and.screwdriver" }
    static func preview(_ text: String, lines: Int) -> String { String(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n").prefix(4096)) }
}

struct NativeToolRow: View {
    let row: NativeRow
    let text: String
    let hasMore: Bool
    let loadMore: () -> Void
    @State private var expanded = false
    private var presentation: NativeToolPresentation { NativeToolPresentation(row: row, text: text) }
    private var needsExpansion: Bool { hasMore || text.count > 4096 || text.components(separatedBy: "\n").count > 5 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(row.title ?? row.kind ?? "工具调用", systemImage: presentation.icon).font(.caption.weight(.semibold))
                Spacer()
                if !presentation.status.isEmpty { Label(presentation.status, systemImage: presentation.symbol).font(.caption2).foregroundStyle(presentation.failed ? Color.red : Color.secondary) }
                if let duration = row.durationMs { Text(String(format: "%.1fs", Double(duration) / 1000)).font(.caption2).foregroundStyle(.secondary) }
            }
            if row.kind == "fileChange" { NativeDiff(content: expanded ? text : NativeToolPresentation.preview(text, lines: 5), wrapsLines: true) }
            else if expanded {
                NativeCodeBlock(text: presentation.input, language: presentation.language)
            } else {
                let input = NativeToolPresentation.preview(presentation.input, lines: 5)
                NativeCodeView(text: .constant(input), language: presentation.language, lineNumbers: false, identifier: "native.tool.input.\(row.key)")
                    .frame(height: CGFloat(min(5, max(1, input.components(separatedBy: "\n").count))) * 20 + 26)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !presentation.output.isEmpty {
                Text("输出").font(.caption2).foregroundStyle(.secondary)
                NativeTerminalOutput(text: expanded ? presentation.output : NativeToolPresentation.preview(presentation.output, lines: 3))
            }
            HStack {
                if needsExpansion {
                    Button(expanded ? "收起内容" : "展开完整内容") { expanded.toggle(); if expanded && hasMore { loadMore() } }.font(.caption)
                }
                if expanded && hasMore { Button("继续加载输出", action: loadMore).font(.caption) }
                Spacer()
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制工具内容")
            }
        }.padding(12).background(Color.linkSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("native.tool.\(row.key)")
    }
}

// Only terminal SGR colors/style affect presentation. OSC links, clipboard
// commands and cursor controls never become tappable links or executable actions.
enum NativeTerminalText {
    static func attributed(_ source: String) -> AttributedString {
        let pattern = #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-_]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        var result = AttributedString(), offset = 0, color: Color?, bold = false
        func append(_ value: String) {
            var segment = AttributedString(value.replacingOccurrences(of: "\r", with: ""))
            if let color { segment.foregroundColor = color }
            if bold { segment.font = .system(.caption, design: .monospaced).bold() }
            result.append(segment)
        }
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            let control = ns.substring(with: match.range)
            if control.hasPrefix("\u{1b}["), control.hasSuffix("m") {
                let values = control.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                let palette: [Color] = [.primary, .red, .green, .yellow, .blue, .purple, .cyan, .secondary]
                var i = 0
                while i < values.count {
                    let value = values[i]
                    if value == 0 { color = nil; bold = false }
                    else if value == 1 { bold = true }
                    else if value == 22 { bold = false }
                    else if value == 39 { color = nil }
                    else if (30...37).contains(value) { color = palette[value - 30] }
                    else if (90...97).contains(value) { color = palette[value - 90] }
                    else if [38, 48].contains(value), i + 1 < values.count {
                        let mode = values[i + 1]
                        if mode == 2 && i + 4 < values.count {
                            if value == 38 { color = Color(red: Double(max(0, min(255, values[i + 2]))) / 255, green: Double(max(0, min(255, values[i + 3]))) / 255, blue: Double(max(0, min(255, values[i + 4]))) / 255) }
                            i += 4
                        } else if mode == 5 && i + 2 < values.count {
                            let index = max(0, min(255, values[i + 2]))
                            if value == 38 {
                                if index < 16 { color = palette[index % 8] }
                                else if index >= 232 { color = Color(white: Double(8 + 10 * (index - 232)) / 255) }
                                else { let n = index - 16; let levels = [0, 95, 135, 175, 215, 255]; color = Color(red: Double(levels[n / 36]) / 255, green: Double(levels[(n / 6) % 6]) / 255, blue: Double(levels[n % 6]) / 255) }
                            }; i += 2
                        }
                    }
                    i += 1
                }
            }
            offset = NSMaxRange(match.range)
        }
        append(ns.substring(from: offset))
        return result
    }
}
struct NativeTerminalOutput: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(NativeTerminalText.attributed(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
        }
    }
}
