import Runestone
import TreeSitterZig
import TreeSitterZigQueries

public extension TreeSitterLanguage {
    static var zig: TreeSitterLanguage {
        let foldsQuery = TreeSitterZigQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterZigQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_zig(), highlightsQuery: highlightsQuery, indentationScopes: .zig, foldsQuery: foldsQuery)
    }
}
