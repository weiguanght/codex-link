import Runestone

public extension TreeSitterIndentationScopes {
    static var kotlin: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "class_body",
                "enum_class_body",
                "function_body",
                "control_structure_body",
                "lambda_literal",
                "when_expression",
                "when_entry",
                "function_value_parameters",
                "value_arguments",
                "collection_literal"
            ],
            outdent: [
                "}",
                ")",
                "]",
                "else",
                "catch",
                "finally"
            ])
    }
}
