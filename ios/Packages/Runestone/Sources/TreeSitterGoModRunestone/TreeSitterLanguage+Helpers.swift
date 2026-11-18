import Runestone
import TreeSitterGoMod
import TreeSitterGoModQueries

public extension TreeSitterLanguage {
    static var goMod: TreeSitterLanguage {
        let foldsQuery = TreeSitterGoModQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterGoModQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_gomod(), highlightsQuery: highlightsQuery, indentationScopes: .goMod, foldsQuery: foldsQuery)
    }
}
