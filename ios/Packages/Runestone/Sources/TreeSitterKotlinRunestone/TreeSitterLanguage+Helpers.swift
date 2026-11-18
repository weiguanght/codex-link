import Runestone
import TreeSitterKotlin
import TreeSitterKotlinQueries

public extension TreeSitterLanguage {
    static var kotlin: TreeSitterLanguage {
        let foldsQuery = TreeSitterKotlinQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterKotlinQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_kotlin(), highlightsQuery: highlightsQuery, indentationScopes: .kotlin, foldsQuery: foldsQuery)
    }
}
