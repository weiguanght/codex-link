import Runestone
import TreeSitterVerilog
import TreeSitterVerilogQueries

public extension TreeSitterLanguage {
    static var verilog: TreeSitterLanguage {
        let foldsQuery = TreeSitterVerilogQueries.Query.foldsFileURL.flatMap { TreeSitterLanguage.Query(contentsOf: $0) }
        let highlightsQuery = TreeSitterLanguage.Query(contentsOf: TreeSitterVerilogQueries.Query.highlightsFileURL)
        return TreeSitterLanguage(tree_sitter_verilog(), highlightsQuery: highlightsQuery, indentationScopes: .verilog, foldsQuery: foldsQuery)
    }
}
