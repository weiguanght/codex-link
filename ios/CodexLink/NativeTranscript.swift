import SwiftUI
import UIKit

struct NativeTranscriptFooterState: Equatable {
    let meta: JSONValue
    let files: [JSONValue]
    let loading: Bool
    let readOnly: Bool
    let pollingError: String
    let error: String
    let notice: String
    let draftStorageError: String
    let downloading: Set<String>
}

/// UIKit owns cell reuse, dragging and self-sizing. SwiftUI renders each message.
struct NativeTranscript: UIViewControllerRepresentable {
    let identity: String
    let rows: [NativeChatRow]
    let footer: AnyView
    let footerState: NativeTranscriptFooterState
    let bottomInset: CGFloat
    let canLoadOlder: Bool
    let loadingOlder: Bool
    let scrollRequest: Int
    let onLoadOlder: () -> Void
    let onFollowing: (Bool) -> Void
    @Environment(\.openURL) private var openURL

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self, openURL: openURL)
    }

    final class Controller: UITableViewController {
        private let footerKey = "native-footer"
        private var source: UITableViewDiffableDataSource<Int, String>!
        private var input: NativeTranscript?
        private var entries: [String: NativeChatRow] = [:]
        private var openURL: OpenURLAction?
        private var following = true
        private var pending = false
        private var applying = false
        private var previousOffset: CGFloat = 0
        private var heights: [String: CGFloat] = [:]
        private var viewportSize: CGSize = .zero

        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.backgroundColor = .clear
            tableView.separatorStyle = .none
            tableView.allowsSelection = false
            tableView.keyboardDismissMode = .interactive
            tableView.contentInsetAdjustmentBehavior = .never
            tableView.rowHeight = UITableView.automaticDimension
            tableView.estimatedRowHeight = 180
            tableView.contentInset.top = 0
            tableView.scrollIndicatorInsets.top = 0
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "message")
            tableView.accessibilityIdentifier = "native.transcript"
            source = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, path, key in
                let cell = table.dequeueReusableCell(withIdentifier: "message", for: path)
                self?.configure(cell, key: key, index: path.row)
                return cell
            }
        }

        private func configure(_ cell: UITableViewCell, key: String, index: Int) {
            guard let input, let openURL else { return }
            #if LINK_SMOKE
            NativeChatRenderMetrics.cellConfigurations += 1
            #endif
            cell.automaticallyUpdatesContentConfiguration = false
            cell.accessibilityIdentifier = "native.message.row." + key
            cell.backgroundColor = .clear
            cell.backgroundConfiguration = .clear()
            if key == footerKey {
                cell.contentConfiguration = UIHostingConfiguration {
                    input.footer.environment(\.openURL, openURL)
                        .padding(.top, 24).padding(.horizontal, 22)
                        .frame(maxWidth: 820).frame(maxWidth: .infinity)
                }.margins(.all, 0)
            } else if let row = entries[key] {
                let compact = index > 0 && row.row.isProcess && input.rows[index - 1].row.isProcess
                cell.contentConfiguration = UIHostingConfiguration {
                    row.equatable().environment(\.openURL, openURL)
                        .task(id: row.cursor + row.row.version.identifier) { await row.onLoadStats() }
                        .padding(.top, index == 0 ? 0 : compact ? 6 : 24)
                        .padding(.horizontal, 22)
                        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.margins(.all, 0)
            }
        }

        func update(_ next: NativeTranscript, openURL: OpenURLAction) {
            loadViewIfNeeded()
            let newIdentity = input?.identity != next.identity
            if input?.loadingOlder == true && !next.loadingOlder { pending = false }
            let explicitBottom = input?.scrollRequest != next.scrollRequest
            let footerChanged = input?.footerState != next.footerState
            let oldIDs = source.snapshot().itemIdentifiers
            let newIDs = next.rows.map { $0.row.key } + [footerKey]
            let nextEntries = Dictionary(uniqueKeysWithValues: next.rows.map { ($0.row.key, $0) })
            var changed = next.rows.filter { entries[$0.row.key] != $0 }.map { $0.row.key }
            let firstMessage = oldIDs.first.flatMap { $0 == footerKey ? nil : $0 }
            let prepend = !newIdentity && firstMessage.flatMap { newIDs.firstIndex(of: $0) }.map { $0 > 0 } == true
            if prepend, let first = oldIDs.first, !changed.contains(first) { changed.append(first) }
            let anchor = prepend ? visibleAnchor() : nil
            input = next; self.openURL = openURL; entries = nextEntries
            if prepend {
                let existing = Set(oldIDs)
                for (index, row) in next.rows.enumerated() where !existing.contains(row.row.key) || row.row.key == firstMessage {
                    let compact = index > 0 && row.row.isProcess && next.rows[index - 1].row.isProcess
                    let host = UIHostingController(rootView: row.environment(\.openURL, openURL)
                        .padding(.top, index == 0 ? 0 : compact ? 6 : 24).padding(.horizontal, 22)
                        .frame(maxWidth: 820).frame(maxWidth: .infinity))
                    let size = host.sizeThatFits(in: CGSize(width: tableView.bounds.width, height: .greatestFiniteMagnitude))
                    heights[row.row.key] = ceil(size.height * tableView.traitCollection.displayScale) / tableView.traitCollection.displayScale
                }
            }
            if tableView.contentInset.bottom != next.bottomInset + 24 {
            tableView.contentInset.bottom = next.bottomInset + 24
                tableView.verticalScrollIndicatorInsets.bottom = next.bottomInset
            }
            if newIdentity { following = true; pending = false; heights.removeAll() }
            if explicitBottom { following = true }
            if oldIDs == newIDs && changed.isEmpty {
                if footerChanged, let path = source.indexPath(for: footerKey), let cell = tableView.cellForRow(at: path) {
                    configure(cell, key: footerKey, index: path.row)
                }
                if explicitBottom { scrollToBottom() }
                return
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(newIDs)
            let existing = Set(oldIDs)
            snapshot.reconfigureItems((changed + (footerChanged ? [footerKey] : [])).filter { existing.contains($0) })
            applying = true
            UIView.performWithoutAnimation {
                source.apply(snapshot, animatingDifferences: false) { [weak self] in
                    guard let self, self.input?.identity == next.identity else { return }
                    self.tableView.layoutIfNeeded()
                    if let anchor, let path = self.source.indexPath(for: anchor.key) {
                        self.tableView.contentOffset.y = self.tableView.rectForRow(at: path).minY - anchor.y
                    } else if self.following { self.scrollToBottom() }
                    self.applying = false
                    if prepend { self.pending = false }
                }
            }
        }

        private func visibleAnchor() -> (key: String, y: CGFloat)? {
            for path in tableView.indexPathsForVisibleRows ?? [] {
                guard let key = source.itemIdentifier(for: path), key != footerKey else { continue }
                let rect = tableView.rectForRow(at: path)
                if rect.maxY > tableView.contentOffset.y {
                    return (key, rect.minY - tableView.contentOffset.y)
                }
            }
            return nil
        }

        private func scrollToBottom() {
            let offset = max(-tableView.adjustedContentInset.top,
                             tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height)
            if abs(tableView.contentOffset.y - offset) > 0.5 { tableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false) }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard viewportSize != tableView.bounds.size else { return }
            viewportSize = tableView.bounds.size
            if following && !applying && !tableView.isTracking && !tableView.isDecelerating { scrollToBottom() }
        }

        override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            source.itemIdentifier(for: indexPath).flatMap { heights[$0] } ?? 180
        }
        override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let key = source.itemIdentifier(for: indexPath) { heights[key] = cell.bounds.height }
        }
        override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            previousOffset = scrollView.contentOffset.y
            setFollowing(false)
        }
        override func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let movingOlder = scrollView.contentOffset.y < previousOffset
            previousOffset = scrollView.contentOffset.y
            guard !applying, scrollView.isDragging || scrollView.isDecelerating else { return }
            if movingOlder, let first = tableView.indexPathsForVisibleRows?.first, first.row <= 8 { loadOlder() }
        }
        override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { didFinishScrolling() }
        }
        override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { didFinishScrolling() }
        private func didFinishScrolling() {
            setFollowing(tableView.contentSize.height - tableView.bounds.maxY <= tableView.adjustedContentInset.bottom + 4)
        }
        private func setFollowing(_ value: Bool) {
            guard following != value else { return }
            following = value; input?.onFollowing(value)
        }
        private func loadOlder() {
            guard input?.canLoadOlder == true, !pending else { return }
            pending = true; input?.onLoadOlder()
        }
    }
}
