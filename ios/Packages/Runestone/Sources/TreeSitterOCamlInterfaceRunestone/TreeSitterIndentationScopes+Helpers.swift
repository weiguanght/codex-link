import Runestone

public extension TreeSitterIndentationScopes {
    static var ocamlInterface: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "signature",
                "class_body_type",
                "record_declaration",
                "parenthesized_module_type",
                "list_expression",
                "array_expression"
            ],
            outdent: [
                "end",
                ")",
                "]",
                "}",
                "|]"
            ])
    }
}
