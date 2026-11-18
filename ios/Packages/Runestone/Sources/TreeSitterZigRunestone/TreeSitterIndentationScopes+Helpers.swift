import Runestone

public extension TreeSitterIndentationScopes {
    static var zig: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "block",
                "initializer_list",
                "switch_expression",
                "parameters",
                "struct_declaration",
                "enum_declaration",
                "union_declaration",
                "opaque_declaration",
                "error_set_declaration"
            ],
            outdent: [
                "}",
                ")",
                "]",
                "else"
            ])
    }
}
