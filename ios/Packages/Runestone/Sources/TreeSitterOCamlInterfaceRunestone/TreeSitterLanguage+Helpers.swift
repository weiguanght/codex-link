import Runestone
import TreeSitterOCamlInterface
import TreeSitterOCamlInterfaceQueries

public extension TreeSitterLanguage {
    static var ocamlInterface: TreeSitterLanguage {
        let foldsQuery = TreeSitterOCamlInterfaceQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterOCamlInterfaceQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_ocaml_interface(), highlightsQuery: highlightsQuery, indentationScopes: .ocamlInterface, foldsQuery: foldsQuery)
    }
}
