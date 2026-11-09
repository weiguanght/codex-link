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

enum NativeHistoryPull {
    static let threshold: CGFloat = 54
    static func damped(_ distance: CGFloat) -> CGFloat { 96.5685 * (sqrt(1 + max(0, distance) / 100) - 1) }
    static func shouldPrefetch(firstVisibleIndex: Int, movingOlder: Bool) -> Bool { movingOlder && firstVisibleIndex <= 8 }
}

@MainActor
final class NativeHistoryScrollController: NSObject, ObservableObject {
    enum Phase { case idle, pulling, armed, loading }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pull: CGFloat = 0
    @Published private(set) var showsLoading = false
    weak var scroll: UIScrollView?
    var enabled = false
    var keys: [String] = []
    var preservingHistory: Bool { requestPending || anchor != nil }
    var onLoad: () -> Void = {}
    var onDragging: (Bool) -> Void = { _ in }
    private var identity = ""
    private var markers: [String: WeakView] = [:]
    private var observation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var requestPending = false
    private var movingOlder = false
    private var managedInset: CGFloat = 0
    private var anchor: (id: String, y: CGFloat)?
    private var restoring = false
    private var haptic = UIImpactFeedbackGenerator(style: .light)
    private var scheduled = false
    private var previousTranslation: CGFloat = 0
    private var topTranslation: CGFloat?
    private var anchorLayoutHeight: CGFloat = 0
    private var anchorRevision = 0
    private var previousKeys: Set<String> = []
    final class WeakView { weak var view: UIView?; init(_ view: UIView) { self.view = view } }

    func configure(identity: String, enabled: Bool, keys: [String], onLoad: @escaping () -> Void, onDragging: @escaping (Bool) -> Void) {
        if self.identity != identity {
            self.identity = identity; requestPending = false; anchor = nil; movingOlder = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.identity == identity, !self.requestPending else { return }
                self.finish()
            }
        }
        self.enabled = enabled; self.keys = keys; self.onLoad = onLoad; self.onDragging = onDragging
    }
    func attach(_ view: UIView) {
        var parent = view.superview
        while let node = parent {
            if let target = node as? UIScrollView {
                guard target !== scroll else { return }
                detach(); scroll = target
                target.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
                observation = target.observe(\.contentOffset, options: [.old, .new]) { @MainActor [weak self] scroll, change in
                    guard let self else { return }
                    // A result may arrive during a drag or inertial scroll. Preserve that
                    // movement while compensating only the displacement caused by layout.
                    if !self.restoring, let saved = self.anchor,
                       scroll.isDragging || scroll.isDecelerating,
                       abs(scroll.contentSize.height - self.anchorLayoutHeight) < 0.25,
                       let old = change.oldValue, let new = change.newValue {
                        self.anchor = (saved.id, saved.y - (new.y - old.y))
                    }
                    self.schedule()
                }
                sizeObservation = target.observe(\.contentSize, options: [.new]) { @MainActor [weak self] _, _ in self?.schedule() }
                return
            }
            parent = node.superview
        }
    }
    func detach() {
        anchor = nil; anchorRevision += 1
        observation = nil; sizeObservation = nil
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
        if let scroll { scroll.contentInset.top -= managedInset }
        managedInset = 0; scroll = nil
    }
    func register(_ id: String, view: UIView) { markers[id] = WeakView(view); schedule() }
    func releaseAnchor() { anchor = nil; anchorRevision += 1 }
    func isInsertedHistory(_ id: String) -> Bool { anchor != nil && !previousKeys.contains(id) }
    private var visibleTop: CGFloat { scroll?.adjustedContentInset.top ?? 0 }
    private func frame(_ view: UIView, in scroll: UIScrollView) -> CGRect { view.convert(view.bounds, to: scroll).offsetBy(dx: -scroll.bounds.minX, dy: -scroll.bounds.minY) }
    private func firstVisible() -> (String, UIView)? {
        guard let scroll else { return nil }
        for id in keys {
            guard let view = markers[id]?.view, view.window != nil else { continue }
            let rect = frame(view, in: scroll)
            if rect.maxY > visibleTop + 1, rect.minY < scroll.bounds.height - scroll.adjustedContentInset.bottom { return (id, view) }
        }
        return nil
    }
    private func schedule() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.scheduled = false; self.scrolled()
        }
    }
    private func scrolled() {
        restoreAnchor()
        guard let scroll, !restoring, anchor == nil else { return }
        let atTop = scroll.contentOffset.y + scroll.adjustedContentInset.top <= 2
        if requestPending && atTop { showFallback() }
        if enabled, !requestPending, movingOlder, scroll.isDragging || scroll.isDecelerating,
           let (id, _) = firstVisible(), let index = keys.firstIndex(of: id),
           NativeHistoryPull.shouldPrefetch(firstVisibleIndex: index, movingOlder: true) { request() }
    }
    private func request() {
        guard enabled, !requestPending else { return }
        requestPending = true; phase = .loading
        onLoad()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.requestPending, let scroll = self.scroll,
                  scroll.contentOffset.y + scroll.adjustedContentInset.top < 10 else { return }
            self.showFallback()
        }
    }
    private func showFallback() {
        guard requestPending, let scroll else { return }
        guard !scroll.isDragging else { return }
        if !showsLoading { showsLoading = true }
        if managedInset == 0 {
            let wasAtTop = scroll.contentOffset.y + scroll.adjustedContentInset.top <= 2
            managedInset = 36
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                scroll.contentInset.top += 36
                if wasAtTop { scroll.contentOffset.y = -scroll.adjustedContentInset.top }
            }
        }
    }
    /// Called immediately before applying the network result, not when the request began.
    func captureAnchor() {
        previousKeys = Set(keys)
        guard let scroll, let (id, view) = firstVisible() else { return }
        anchor = (id, frame(view, in: scroll).minY)
        anchorLayoutHeight = scroll.contentSize.height
    }
    private func restoreAnchor() {
        guard !restoring, let anchor, let scroll else { return }
        let delta: CGFloat
        if let view = markers[anchor.id]?.view, view.window != nil {
            delta = frame(view, in: scroll).minY - anchor.y
        } else {
            // A large prepend can temporarily evict the anchor from LazyVStack.
            // Compensate the measured height first so that row can materialize again.
            delta = scroll.contentSize.height - anchorLayoutHeight
        }
        anchorLayoutHeight = scroll.contentSize.height
        guard abs(delta) > 0.25 else { return }
        restoring = true
        UIView.performWithoutAnimation { scroll.contentOffset.y += delta }
        restoring = false
    }
    func finish() {
        restoreAnchor()
        requestPending = false; movingOlder = false
        if let scroll, managedInset > 0 {
            let inset = managedInset; managedInset = 0
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) { scroll.contentInset.top -= inset }
        }
        withAnimation(.easeOut(duration: 0.16)) { phase = .idle; pull = 0; showsLoading = false }
        // Keep correcting lazy measurement briefly, without pinning future programmatic scrolls.
        anchorRevision += 1
        let revision = anchorRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.anchorRevision == revision else { return }
            self.restoreAnchor(); self.anchor = nil
        }
        schedule()
    }
    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        guard let scroll else { return }
        let translation = pan.translation(in: scroll.window).y
        let atTop = scroll.contentOffset.y + scroll.adjustedContentInset.top <= 2
        switch pan.state {
        case .began:
            releaseAnchor(); previousTranslation = translation; topTranslation = atTop ? translation : nil
            movingOlder = pan.velocity(in: scroll).y > 0; haptic.prepare(); onDragging(true)
        case .changed:
            movingOlder = translation > previousTranslation; previousTranslation = translation
            if atTop && topTranslation == nil { topTranslation = translation }
            if let start = topTranslation, enabled || requestPending {
                let distance = NativeHistoryPull.damped(translation - start)
                pull = min(74, distance)
                if !showsLoading {
                    let reached = distance >= NativeHistoryPull.threshold
                    if reached && phase != .armed { haptic.impactOccurred() }
                    phase = reached ? .armed : .pulling
                }
                if atTop && distance > 0 {
                    UIView.performWithoutAnimation { scroll.contentOffset.y = -scroll.adjustedContentInset.top - distance }
                }
            }
            scrolled()
        case .ended:
            onDragging(false)
            if phase == .armed { request() }
            if requestPending && atTop { showFallback() }
            else if !requestPending { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0; phase = .idle } }
            topTranslation = nil
        case .cancelled, .failed:
            onDragging(false); movingOlder = false; topTranslation = nil
            if requestPending && atTop { showFallback() }
            else if !requestPending { withAnimation { pull = 0; phase = .idle } }
        default: break
        }
    }
}

/// Only newly inserted history fades; existing visible rows never animate position.
@MainActor
struct NativeHistoryReveal: ViewModifier {
    @State private var opacity: Double
    init(id: String, controller: NativeHistoryScrollController) {
        _opacity = State(initialValue: controller.isInsertedHistory(id) ? 0 : 1)
    }
    func body(content: Content) -> some View {
        content.opacity(opacity).onAppear { withAnimation(.easeOut(duration: 0.18)) { opacity = 1 } }
    }
}

struct NativeHistoryScrollProbe: UIViewRepresentable {
    let controller: NativeHistoryScrollController
    let identity: String
    let enabled: Bool
    let keys: [String]
    let onLoad: () -> Void
    let onDragging: (Bool) -> Void
    func makeCoordinator() -> NativeHistoryScrollController { controller }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.isUserInteractionEnabled = false
        view.attached = { [weak controller] view in controller?.attach(view) }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        controller.configure(identity: identity, enabled: enabled, keys: keys, onLoad: onLoad, onDragging: onDragging)
        controller.attach(view)
    }
    static func dismantleUIView(_ view: Probe, coordinator: NativeHistoryScrollController) { view.attached = nil; coordinator.detach() }
    final class Probe: UIView {
        var attached: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); attached?(self) }
        override func didMoveToSuperview() { super.didMoveToSuperview(); attached?(self) }
    }
}
struct NativeHistoryRowMarker: UIViewRepresentable {
    let id: String
    let controller: NativeHistoryScrollController
    func makeUIView(context: Context) -> Marker { let view = Marker(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: Marker, context: Context) {
        view.laidOut = { [weak controller, weak view] in if let view { controller?.register(id, view: view) } }
        controller.register(id, view: view)
    }
    final class Marker: UIView {
        var laidOut: (() -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); laidOut?() }
    }
}
struct NativeHistoryIndicator: View {
    @ObservedObject var controller: NativeHistoryScrollController
    var body: some View {
        let height = controller.showsLoading ? 36 : controller.pull
        Group {
            if height > 0 {
                Group {
                    if controller.showsLoading { ProgressView().controlSize(.mini) }
                    else {
                        Circle().trim(from: 0, to: min(1, controller.pull / NativeHistoryPull.threshold))
                            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(Double(controller.pull / NativeHistoryPull.threshold) * 270 - 90))
                            .scaleEffect(controller.phase == .armed ? 1.12 : 1)
                            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: controller.phase == .armed)
                            .frame(width: 13, height: 13)
                    }
                }.frame(maxWidth: .infinity).frame(height: height).clipped()
            }
        }.allowsHitTesting(false).accessibilityIdentifier("native.history.loading")
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
            } else if let parsed = NativeMarkdownTable.parse(lines, at: index) {
                appendProse()
                blocks.append(NativeMarkdownBlock(id: blocks.count, content: "", table: parsed.table))
                index = parsed.end
            } else { prose.append(lines[index]); index += 1 }
        }
        appendProse(); return blocks
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
                Text(NativeMessageLinks.attributed(cells[column]))
                    .fontWeight(header ? .semibold : .regular)
                    .multilineTextAlignment(table.alignments[column] == .trailing ? .trailing : table.alignments[column] == .center ? .center : .leading)
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
    let onSend: () -> Void
    let onChooseMode: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.accessibilityLabel = "发送消息"
        button.accessibilityHint = "轻点按默认方式发送，长按选择本次发送方式"
        button.accessibilityIdentifier = "native.send"
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45; hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "选择发送方式", target: context.coordinator, selector: #selector(Coordinator.choose))]
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.owner = self
        button.isEnabled = enabled; button.alpha = enabled ? 1 : 0.3
        button.backgroundColor = .label; button.tintColor = .systemBackground
    }
    final class Coordinator: NSObject {
        var owner: NativeSendButton
        init(_ owner: NativeSendButton) { self.owner = owner }
        @objc func tap() { if owner.enabled { owner.onSend() } }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began && owner.enabled { UIImpactFeedbackGenerator(style: .light).impactOccurred(); owner.onChooseMode() }
        }
        @objc func choose() -> Bool { guard owner.enabled else { return false }; owner.onChooseMode(); return true }
    }
}
