import Runestone
import TreeSitterDockerfile
import TreeSitterDockerfileQueries

public extension TreeSitterLanguage {
    static var dockerfile: TreeSitterLanguage {
        let foldsQuery = TreeSitterDockerfileQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterDockerfileQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_dockerfile(), highlightsQuery: highlightsQuery, indentationScopes: .dockerfile, foldsQuery: foldsQuery)
    }
}
