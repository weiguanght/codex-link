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
            .padding(13).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }
}
struct NativeMarkdown: View {
    let text: String
    private struct Block: Identifiable {
        let id: Int
        let content: String
        let code: Bool
        let language: String
    }
    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = [], current: [String] = [], code = false, language = ""
        func append() { if !current.isEmpty { result.append(Block(id: result.count, content: current.joined(separator: "\n"), code: code, language: language)); current = [] } }
        for line in lines {
            if line.hasPrefix("```") { append(); code.toggle(); language = code ? String(line.dropFirst(3)) : "" }
            else { current.append(line) }
        }
        append(); return result
    }
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
                        ScrollView(.horizontal) { Text(block.content).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    }.padding(14).background(Color.linkSurface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    // Foundation Markdown handles emphasis and links; block rows
                    // remain SwiftUI text, including headings and lists.
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(block.content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            markdownLine(line)
                        }
                    }.textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func markdownLine(_ line: String) -> some View {
        let heading = line.prefix(while: { $0 == "#" }).count
        if line == "---" || line == "***" { Divider().padding(.vertical, 8) }
        else if heading > 0 && heading <= 6 && line.dropFirst(heading).hasPrefix(" ") {
            Text(inline(String(line.dropFirst(heading + 1))))
                .font(heading <= 2 ? .title3.weight(.semibold) : .headline).padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) { Text("•"); Text(inline(String(line.dropFirst(2)))).frame(maxWidth: .infinity, alignment: .leading) }
        } else if line.hasPrefix("> ") {
            HStack(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 3); Text(inline(String(line.dropFirst(2)))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        } else if line.isEmpty { Color.clear.frame(height: 5) }
        else { Text(inline(line)).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}
struct ShareView: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
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
