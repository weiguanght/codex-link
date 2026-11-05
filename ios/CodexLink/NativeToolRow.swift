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
}

/// Unwrap one quoted command argument to a known shell for display only.
/// Compound invocations retain their original text. Nothing is executed here.
enum NativeShellCommand {
    static func display(_ source: String, allowIncomplete: Bool = false) -> String {
        var index = source.startIndex
        func skipSpace() { while index < source.endIndex && source[index].isWhitespace { source.formIndex(after: &index) } }
        func token() -> String {
            skipSpace(); let start = index
            while index < source.endIndex && !source[index].isWhitespace { source.formIndex(after: &index) }
            return String(source[start..<index])
        }
        let shell = (token() as NSString).lastPathComponent
        guard ["zsh", "bash", "sh", "dash", "ksh", "fish"].contains(shell) else { return source }
        while true {
            let option = token()
            if option == "--command" { break }
            if ["--login", "--interactive", "--noprofile", "--norc"].contains(option) { continue }
            guard option.hasPrefix("-"), option.count > 1,
                  option.dropFirst().allSatisfy({ "lic".contains($0) }) else { return source }
            if option.contains("c") { break }
        }
        skipSpace()
        guard index < source.endIndex, source[index] == "\"" || source[index] == "'" else { return source }
        var quote: Character?, result = ""
        while index < source.endIndex {
            let character = source[index]; source.formIndex(after: &index)
            if let current = quote {
                if character == current { quote = nil }
                else if current == "\"", character == "\\", index < source.endIndex {
                    let next = source[index]
                    if "\"\\$`".contains(next) || next == "\n" {
                        source.formIndex(after: &index)
                        if next != "\n" { result.append(next) }
                    } else { result.append(character) }
                } else { result.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace {
                skipSpace()
                return index == source.endIndex ? result : source
            } else if character == "\\", index < source.endIndex {
                result.append(source[index]); source.formIndex(after: &index)
            } else if ";|&<>()".contains(character) { return source }
            else { result.append(character) }
        }
        return quote == nil || allowIncomplete ? result : source
    }
}

/// Every tool uses the chat's single detail sheet; the transcript never embeds output.
struct NativeToolRow: View {
    let row: NativeRow
    let text: String
    let open: () -> Void
    private var presentation: NativeToolPresentation { NativeToolPresentation(row: row, text: text) }
    private var summary: String {
        let original = presentation.input
        let command = row.kind == "commandExecution"
            ? NativeShellCommand.display(original, allowIncomplete: (row.inputLength ?? 0) > original.unicodeScalars.count)
            : original
        let input = command.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        return row.kind == "fileChange" ? (row.title ?? "文件变更") : input.isEmpty ? (row.title ?? "工具调用") : input
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: presentation.icon).foregroundStyle(.secondary)
                NativeSyntaxText(text: summary, language: presentation.language, singleLine: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: presentation.symbol).foregroundStyle(presentation.failed ? Color.red : Color.secondary)
                    .accessibilityLabel(presentation.status)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.linkSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("native.tool.\(row.key)")
    }
}

struct NativeToolDetail: View {
    @ObservedObject var chat: ChatModel
    let rowKey: String
    let sessionIdentity: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.commandLineWrapping") private var commandWrapping = true
    @AppStorage("native.diffLineWrapping") private var diffWrapping = true
    @State private var loading = false
    @State private var error = ""
    private var row: NativeRow? { chat.session?.identity == sessionIdentity ? chat.rows.first { $0.key == rowKey } : nil }
    private var wrapsLines: Binding<Bool> { row?.kind == "fileChange" ? $diffWrapping : $commandWrapping }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let row {
                    let text = chat.rowText(row)
                    let presentation = NativeToolPresentation(row: row, text: text)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label(presentation.status, systemImage: presentation.symbol).foregroundStyle(presentation.failed ? Color.red : Color.secondary)
                            Spacer()
                            if let duration = row.durationMs { Text(String(format: "%.1fs", Double(duration) / 1000)).foregroundStyle(.secondary) }
                        }.font(.caption)
                        if row.kind == "fileChange" {
                            NativeDiff(content: text, wrapsLines: diffWrapping)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(row.kind == "commandExecution" ? "命令" : "输入").font(.subheadline.weight(.semibold))
                                NativeSyntaxText(text: presentation.input, language: presentation.language, wrapsLines: commandWrapping)
                                    .padding(12).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityIdentifier("native.tool.detail.input")
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("输出").font(.subheadline.weight(.semibold))
                                if !presentation.output.isEmpty {
                                    NativeTerminalOutput(text: presentation.output, wrapsLines: commandWrapping)
                                        .accessibilityIdentifier("native.tool.detail.output")
                                } else if !loading {
                                    Text(["running", "inProgress", "in_progress"].contains(row.status ?? "") ? "等待输出…" : "无输出").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if loading { ProgressView("正在加载完整内容…").font(.caption) }
                        if !error.isEmpty {
                            NativeNotice(text: error, isError: true)
                            Button("重试加载") { Task { await loadRemaining() } }.disabled(loading)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                } else { Text("此工具记录已不可用").foregroundStyle(.secondary).padding() }
            }
            .navigationTitle(row?.kind == "fileChange" ? "文件变更" : row?.kind == "commandExecution" ? "执行命令" : "工具详情")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("native.tool.detail")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Toggle("自动换行", isOn: wrapsLines)
                        Button("复制全部", systemImage: "doc.on.doc") { if let row { UIPasteboard.general.string = chat.rowText(row) } }
                        if let row, row.kind == "commandExecution" {
                            Button("复制命令", systemImage: "terminal") { UIPasteboard.general.string = NativeToolPresentation(row: row, text: chat.rowText(row)).input }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("详情选项")
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task(id: row?.version) { await loadRemaining() }
        }
    }
    private func loadRemaining() async {
        loading = true; error = ""
        defer { loading = false }
        do {
            while let current = row, chat.rowHasMore(current) {
                try Task.checkCancellation()
                try await chat.expand(current)
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
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
    var wrapsLines = false
    var body: some View {
        Group {
            if wrapsLines {
                output.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) { output.fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
    private var output: some View {
        Text(NativeTerminalText.attributed(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
}
