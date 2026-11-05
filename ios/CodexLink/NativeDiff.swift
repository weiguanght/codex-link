import SwiftUI

/// Parses unified patches, apply_patch blocks and the desktop's path + diff projection.
/// Paths and code are data, never interpreted as Markdown, HTML or links.
struct NativeDiffDocument {
    enum Kind: Hashable { case context, addition, deletion, hunk, note }
    struct Line: Identifiable, Hashable {
        let id: Int
        let kind: Kind
        let text: String
        let old: Int?
        let new: Int?
    }
    struct File: Identifiable, Hashable {
        let id: Int
        var path: String
        var previousPath: String?
        var lines: [Line] = []
        var additions: Int { lines.filter { $0.kind == .addition }.count }
        var deletions: Int { lines.filter { $0.kind == .deletion }.count }
    }
    var files: [File] = []
    init(_ content: String) {
        let source = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var file: File?, old: Int?, new: Int?, oldRemaining = 0, newRemaining = 0
        var inHunk = false, applyPatch = false
        func flush() { if let current = file { files.append(current) }; file = nil; old = nil; new = nil; inHunk = false }
        func start(_ path: String) { flush(); file = File(id: files.count, path: path) }
        func append(_ kind: Kind, _ text: String) {
            if file == nil { file = File(id: files.count, path: "变更") }
            let hasOld = kind == .context || kind == .deletion
            let hasNew = kind == .context || kind == .addition
            file!.lines.append(Line(id: file!.lines.count, kind: kind, text: text, old: hasOld ? old : nil, new: hasNew ? new : nil))
            if hasOld { old = old.map { $0 + 1 }; oldRemaining = max(0, oldRemaining - 1) }
            if hasNew { new = new.map { $0 + 1 }; newRemaining = max(0, newRemaining - 1) }
            if !applyPatch && oldRemaining == 0 && newRemaining == 0 { inHunk = false }
        }
        let hunk = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$"#)
        for (index, line) in source.enumerated() {
            if line == "*** Begin Patch" { applyPatch = true; continue }
            if line == "*** End Patch" || line == "*** End of File" { continue }
            if let prefix = ["*** Update File: ", "*** Add File: ", "*** Delete File: "].first(where: { line.hasPrefix($0) }) {
                applyPatch = true; start(String(line.dropFirst(prefix.count)))
                if prefix == "*** Add File: " { new = 1 }
                if prefix == "*** Delete File: " { old = 1 }
                continue
            }
            if line.hasPrefix("*** Move to: ") {
                let previous = file?.path
                file?.previousPath = previous; file?.path = String(line.dropFirst(13)); continue
            }
            if line.hasPrefix("diff --git ") {
                applyPatch = false
                // The ---/+++ headers below supply authoritative paths, including spaces.
                let tail = String(line.dropFirst(11))
                let path = tail.range(of: " b/").map { String(tail[$0.upperBound...]) }
                // A desktop path preceding a full git patch is only a label.
                if file?.lines.isEmpty == true { file = nil }
                start(path ?? "变更"); continue
            }
            if !inHunk && line.hasPrefix("--- ") {
                let path = Self.path(String(line.dropFirst(4)))
                if file == nil || file?.lines.contains(where: { $0.kind != .note }) == true { start(path) }
                file?.previousPath = path; continue
            }
            if !inHunk && line.hasPrefix("+++ ") {
                let path = Self.path(String(line.dropFirst(4)))
                if file == nil { start(path) }
                if path != "/dev/null" { file?.path = path }
                else if let previous = file?.previousPath { file?.path = previous }
                continue
            }
            let ns = line as NSString
            if let match = hunk.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                func number(_ group: Int, fallback: Int = 1) -> Int { match.range(at: group).location == NSNotFound ? fallback : Int(ns.substring(with: match.range(at: group))) ?? fallback }
                old = number(1); new = number(3); oldRemaining = number(2); newRemaining = number(4)
                append(.hunk, ns.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces))
                inHunk = true; continue
            }
            if applyPatch && line.hasPrefix("@@") { append(.hunk, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)); inHunk = true; continue }
            if line.hasPrefix("index ") { continue }
            if line.hasPrefix("rename from ") { file?.previousPath = String(line.dropFirst(12)); continue }
            if line.hasPrefix("rename to ") { file?.path = String(line.dropFirst(10)); continue }
            if ["new file mode ", "deleted file mode ", "old mode ", "new mode ", "similarity index ", "dissimilarity index ", "Binary files ", "GIT binary patch"].contains(where: { line.hasPrefix($0) }) {
                append(.note, line); continue
            }
            // Desktop fileChange text is `path\npatch\n\npath\npatch`.
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("+") && !line.hasPrefix("-") && !line.hasPrefix("\\") && !line.hasPrefix("***") {
                let next = index + 1 < source.count ? source[index + 1] : ""
                if next.hasPrefix("@@") || next.hasPrefix("--- ") || next.hasPrefix("diff --git ") || next.hasPrefix("+") || next.hasPrefix("-") {
                    start(line); continue
                }
            }
            if line.hasPrefix("+") { append(.addition, String(line.dropFirst())) }
            else if line.hasPrefix("-") { append(.deletion, String(line.dropFirst())) }
            else if line.hasPrefix(" ") { append(.context, String(line.dropFirst())) }
            else if line.hasPrefix("\\ No newline") { append(.note, "文件末尾无换行") }
            else if !line.isEmpty { append(.note, line) }
        }
        flush()
    }
    private static func path(_ text: String) -> String {
        var path = text.components(separatedBy: "\t")[0]
        if path.hasPrefix("\""), let bytes = Self.gitPathBytes(path), let decoded = String(bytes: bytes, encoding: .utf8) { path = decoded }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path
    }
    private static func gitPathBytes(_ text: String) -> [UInt8]? {
        guard text.hasSuffix("\"") else { return nil }
        let source = Array(text.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = [], index = 0
        while index < source.count {
            if source[index] == 92, index + 1 < source.count {
                index += 1
                if (48...55).contains(source[index]) {
                    var value = 0, count = 0
                    while index < source.count, count < 3, (48...55).contains(source[index]) { value = value * 8 + Int(source[index] - 48); index += 1; count += 1 }
                    guard value <= 255 else { return nil }; bytes.append(UInt8(value)); continue
                }
                let escapes: [UInt8: UInt8] = [116: 9, 110: 10, 114: 13, 92: 92, 34: 34]
                bytes.append(escapes[source[index]] ?? source[index])
            } else { bytes.append(source[index]) }
            index += 1
        }
        return bytes
    }
}

struct NativeDiff: View {
    let content: String
    let wrapsLines: Bool
    @State private var document = NativeDiffDocument("")
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(document.files) { file in NativeDiffFile(file: file, wrapsLines: wrapsLines) }
        }
        .task(id: content) {
            let parsed = await Task.detached(priority: .userInitiated) { NativeDiffDocument(content) }.value
            if !Task.isCancelled { document = parsed }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("代码差异")
    }
}

private struct NativeDiffFile: View {
    let file: NativeDiffDocument.File
    let wrapsLines: Bool
    @State private var collapsed = false
    @State private var highlighted: [Int: AttributedString] = [:]
    @Environment(\.colorScheme) private var colorScheme
    private struct Request: Hashable { let file: NativeDiffDocument.File; let dark: Bool }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { collapsed.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.path).font(.system(.caption, design: .monospaced).weight(.semibold)).multilineTextAlignment(.leading)
                        if let previous = file.previousPath, previous != file.path, previous != "/dev/null" {
                            Text("原路径：" + previous).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }.font(.caption).padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).background(Color.linkSurface)
            if !collapsed {
                if wrapsLines { lines }
                else { ScrollView(.horizontal) { lines.fixedSize(horizontal: true, vertical: false) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
        .task(id: Request(file: file, dark: colorScheme == .dark)) {
            let result = await Task.detached(priority: .userInitiated) { () -> [Int: AttributedString] in
                // Parse each file once so multiline language context survives across rows.
                let code = file.lines.filter { [.context, .addition, .deletion].contains($0.kind) }
                let source = code.map(\.text).joined(separator: "\n")
                let attributed = NativeSyntaxHighlight.text(source, language: file.path)
                let ns = NSAttributedString(attributed)
                var offset = 0, result: [Int: AttributedString] = [:]
                for line in code {
                    let length = (line.text as NSString).length
                    let range = NSRange(location: offset, length: length)
                    if NSMaxRange(range) <= ns.length { result[line.id] = try? AttributedString(ns.attributedSubstring(from: range), including: \.uiKit) }
                    offset += length + 1
                }
                return result
            }.value
            if !Task.isCancelled { highlighted = result }
        }
    }
    private var lines: some View {
        let width = gutterWidth
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(file.lines) { line in
                HStack(alignment: .top, spacing: 0) {
                    if [.hunk, .note].contains(line.kind) {
                        Text(line.text.isEmpty ? "变更片段" : line.text).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                    } else {
                        Text(line.old.map(String.init) ?? "").frame(width: width, alignment: .trailing).foregroundStyle(.secondary)
                        Text(line.new.map(String.init) ?? "").frame(width: width, alignment: .trailing).foregroundStyle(.secondary).padding(.trailing, 6)
                        Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                            .foregroundStyle(line.kind == .addition ? Color.green : line.kind == .deletion ? Color.red : Color.secondary).frame(width: 14)
                        Text(highlighted[line.id] ?? AttributedString(line.text.isEmpty ? " " : line.text))
                            .fixedSize(horizontal: !wrapsLines, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8).textSelection(.enabled)
                    }
                }
                .font(.system(size: 13, design: .monospaced)).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(line.kind))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("native.diff.line.\(file.id).\(line.id)")
            }
        }
    }
    private var gutterWidth: CGFloat {
        let largest = file.lines.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0
        return CGFloat(max(2, String(largest).count)) * 8 + 5
    }
    private func background(_ kind: NativeDiffDocument.Kind) -> Color {
        switch kind {
        case .addition: return .green.opacity(0.12)
        case .deletion: return .red.opacity(0.12)
        case .hunk: return .blue.opacity(0.07)
        default: return .clear
        }
    }
}
