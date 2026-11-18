import SwiftUI
import UIKit

enum NativeBackNavigation {
    static func shouldFinish(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress >= 0.38 || (progress > 0.02 && velocity >= 800)
    }
}

/// A window-level edge recognizer leaves vertical scrolling and text selection intact.
struct NativeBackPanObserver: UIViewRepresentable {
    let enabled: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.isUserInteractionEnabled = false
        view.attached = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { context.coordinator.owner = self; context.coordinator.attach(view) }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var attached: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); attached?(self) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: NativeBackPanObserver
        weak var probe: UIView?
        weak var window: UIWindow?
        let recognizer = UIScreenEdgePanGestureRecognizer()
        init(_ owner: NativeBackPanObserver) {
            self.owner = owner; super.init()
            recognizer.edges = .left; recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(pan(_:)))
        }
        func attach(_ view: UIView) {
            probe = view
            guard let target = view.window, target !== window else { return }
            detach(); probe = view; window = target; target.addGestureRecognizer(recognizer)
        }
        func detach() { window?.removeGestureRecognizer(recognizer); window = nil }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.enabled, let probe, let window, window.rootViewController?.presentedViewController == nil else { return false }
            let velocity = recognizer.velocity(in: window)
            return probe.convert(probe.bounds, to: window).contains(recognizer.location(in: window))
                && velocity.x > abs(velocity.y)
        }
        @objc func pan(_ pan: UIScreenEdgePanGestureRecognizer) {
            let distance = max(0, pan.translation(in: window).x)
            switch pan.state {
            case .began, .changed: owner.onChange(distance)
            case .ended: owner.onEnd(distance, pan.velocity(in: window).x, false)
            case .cancelled, .failed: owner.onEnd(distance, 0, true)
            default: break
            }
        }
    }
}

/// Center one shared column, then align every file label to its leading edge.
struct NativeFileListLayout: Layout {
    private func measurements(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGFloat, CGFloat, [CGSize]) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let available = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? ideal
        let width = min(ideal, available)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return (available, width, sizes)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (available, _, sizes) = measurements(proposal, subviews)
        return CGSize(width: available, height: sizes.reduce(0) { $0 + $1.height })
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, width, sizes) = measurements(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.midX - width / 2, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: sizes[index].height))
            y += sizes[index].height
        }
    }
}

struct NativeMarkdownTable {
    enum ColumnAlignment { case leading, center, trailing }
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    /// GFM pipes inside a code span or escaped with a backslash stay in a cell.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", codeFence = 0
        let chars = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                cell.append(char); cell.append(chars[index + 1]); index += 2; continue
            }
            if char == "`" {
                var end = index
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - index
                if codeFence == 0 { codeFence = count } else if count == codeFence { codeFence = 0 }
                cell += String(repeating: "`", count: count); index = end; continue
            }
            if char == "|" && codeFence == 0 { cells.append(cell); cell = "" }
            else { cell.append(char) }
            index += 1
        }
        cells.append(cell)
        if chars.first == "|" { cells.removeFirst() }
        if chars.last == "|", cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func parse(_ lines: [String], at start: Int) -> (table: NativeMarkdownTable, end: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let headers = cells(lines[start]), separators = cells(lines[start + 1])
        guard !headers.isEmpty, headers.count == separators.count else { return nil }
        var alignments: [ColumnAlignment] = []
        for separator in separators {
            let dashes = separator.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(separator.hasSuffix(":") ? separator.hasPrefix(":") ? .center : .trailing : .leading)
        }
        var rows: [[String]] = [], end = start + 2
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty, lines[end].contains("|") {
            let values = cells(lines[end])
            rows.append(Array((values + Array(repeating: "", count: headers.count)).prefix(headers.count)))
            end += 1
        }
        return (NativeMarkdownTable(headers: headers, alignments: alignments, rows: rows), end)
    }
}

struct NativeMarkdownBlock: Identifiable {
    let id: Int
    let content: String
    var code = false
    var language = ""
    var table: NativeMarkdownTable?

    static func parse(_ text: String) -> [NativeMarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [NativeMarkdownBlock] = [], prose: [String] = [], index = 0
        func appendProse() {
            if !prose.isEmpty { blocks.append(NativeMarkdownBlock(id: blocks.count, content: prose.joined(separator: "\n"))); prose = [] }
        }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            let fence = line.prefix(while: { $0 == "`" || $0 == "~" })
            if fence.count >= 3, Set(fence).count == 1 {
                appendProse()
                let language = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var content: [String] = []; index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.prefix(while: { $0 == fence.first! }).count >= fence.count && candidate.allSatisfy({ $0 == fence.first! }) { break }
                    content.append(lines[index]); index += 1
                }
                blocks.append(NativeMarkdownBlock(id: blocks.count, content: content.joined(separator: "\n"), code: true, language: language))
                index += 1
            } else if let end = displayMathEnd(lines, at: index) {
                prose.append(contentsOf: lines[index...end])
                index = end + 1
            } else if let parsed = NativeMarkdownTable.parse(lines, at: index) {
                appendProse()
                blocks.append(NativeMarkdownBlock(id: blocks.count, content: "", table: parsed.table))
                index = parsed.end
            } else { prose.append(lines[index]); index += 1 }
        }
        appendProse(); return blocks
    }

    private static func displayMathEnd(_ lines: [String], at start: Int) -> Int? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let delimiter: String
        if first.hasPrefix("$$") { delimiter = "$$" }
        else if first.hasPrefix("\\[") { delimiter = "\\]" }
        else { return nil }
        let remainder = first.dropFirst(2)
        if remainder.hasSuffix(delimiter) { return start }
        var length = remainder.utf16.count
        for index in (start + 1)..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            length += line.utf16.count + 1
            if length > 4_096 { return nil }
            if line.hasSuffix(delimiter) { return index }
        }
        return nil
    }
}

struct NativeMarkdownTableView: View {
    let table: NativeMarkdownTable
    @Environment(\.dynamicTypeSize) private var typeSize
    private var widths: [CGFloat] {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return table.headers.indices.map { column in
            let values = [table.headers[column]] + table.rows.map { $0[column] }
            return min(280, max(90, values.map { (String(NativeMessageLinks.attributed($0).characters) as NSString).size(withAttributes: [.font: font]).width + 24 }.max() ?? 90))
        }
    }
    var body: some View {
        let columns = widths
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                tableRow(table.headers, columns: columns, header: true)
                    .background(Color.linkSurface)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    Divider()
                    tableRow(cells, columns: columns, header: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.linkSurface.opacity(0.5))
                }
            }.fixedSize(horizontal: false, vertical: true)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityIdentifier("native.markdown.table").textSelection(.enabled)
    }
    private func tableRow(_ cells: [String], columns: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.headers.indices, id: \.self) { column in
                let alignment: Alignment = table.alignments[column] == .trailing ? .trailing : table.alignments[column] == .center ? .center : .leading
                Group {
                    if NativeMarkdownMath.mayContainMath(cells[column]) {
                        NativeSelectableText(text: cells[column], cell: true, bold: header, alignment: table.alignments[column])
                    } else {
                        Text(NativeMessageLinks.attributed(cells[column]))
                            .fontWeight(header ? .semibold : .regular)
                            .multilineTextAlignment(table.alignments[column] == .trailing ? .trailing : table.alignments[column] == .center ? .center : .leading)
                    }
                }
                .frame(width: columns[column] - 24, alignment: alignment)
                .padding(12).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum NativeTokenCount {
    /// Decimal K/M, matching the compact display used by Codex /status.
    static func format(_ count: Int) -> String {
        let count = max(0, count)
        guard count >= 1_000 else { return String(count) }
        let millions = count >= 999_500
        let scaled = Double(count) / (millions ? 1_000_000 : 1_000)
        let decimals = scaled < 10 ? 2 : scaled < 100 ? 1 : 0
        var text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, scaled)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text + (millions ? "M" : "K")
    }
}

struct NativeContextUsage {
    let used: Int
    let window: Int
    init?(_ value: JSONValue) {
        guard case .number(let used) = value["usedTokens"], case .number(let window) = value["windowTokens"],
              used.isFinite, window.isFinite, used >= 0, window > 0,
              used <= 1e15, window <= 1e15 else { return nil }
        self.used = Int(used); self.window = Int(window)
    }
    var percentage: String { String(format: "%.1f%%", Double(used) / Double(window) * 100) }
    var placeholder: String { "\(NativeTokenCount.format(used)) / \(NativeTokenCount.format(window))（\(percentage)）" }
}

/// One recognizer owns the hold; releasing it must never also send a message.
struct NativeSendButton: UIViewRepresentable {
    let enabled: Bool
    let allowsModeSelection: Bool
    let onSend: () -> Void
    let onChooseMode: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.accessibilityLabel = "发送消息"
        button.accessibilityIdentifier = "native.send"
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45; hold.cancelsTouchesInView = true
        hold.isEnabled = enabled && allowsModeSelection
        button.addGestureRecognizer(hold)
        context.coordinator.holdRecognizer = hold
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.owner = self
        button.isEnabled = enabled; button.alpha = enabled ? 1 : 0.3
        context.coordinator.holdRecognizer?.isEnabled = enabled && allowsModeSelection
        button.accessibilityHint = allowsModeSelection ? "轻点按默认方式发送，长按选择本次发送方式" : "轻点发送新消息"
        button.accessibilityCustomActions = allowsModeSelection
            ? [UIAccessibilityCustomAction(name: "选择发送方式", target: context.coordinator, selector: #selector(Coordinator.choose))] : nil
        button.backgroundColor = .label; button.tintColor = .systemBackground
    }
    final class Coordinator: NSObject {
        var owner: NativeSendButton
        var holdRecognizer: UILongPressGestureRecognizer?
        init(_ owner: NativeSendButton) { self.owner = owner }
        @objc func tap() { if owner.enabled { owner.onSend() } }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began && owner.enabled && owner.allowsModeSelection { UIImpactFeedbackGenerator(style: .light).impactOccurred(); owner.onChooseMode() }
        }
        @objc func choose() -> Bool { guard owner.enabled && owner.allowsModeSelection else { return false }; owner.onChooseMode(); return true }
    }
}
