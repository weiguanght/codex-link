import Runestone

public extension TreeSitterIndentationScopes {
    /// Indent JSON-form instructions; shell continuations retain their current indentation.
    static var dockerfile: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "json_string_array"
            ],
            outdent: [
                "]"
            ])
    }
}
