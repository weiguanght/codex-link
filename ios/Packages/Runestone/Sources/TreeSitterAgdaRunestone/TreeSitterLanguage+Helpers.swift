import Runestone
import TreeSitterAgda
import TreeSitterAgdaQueries

public extension TreeSitterLanguage {
    static var agda: TreeSitterLanguage {
        let foldsQuery = TreeSitterAgdaQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterAgdaQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_agda(), highlightsQuery: highlightsQuery, indentationScopes: .agda, foldsQuery: foldsQuery)
    }
}
