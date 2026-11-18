import Runestone

public extension TreeSitterIndentationScopes {
    static var agda: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "let",
                "do",
                "private",
                "abstract",
                "mutual",
                "postulate",
                "field",
                "record_declarations_block",
                "(",
                "{",
                "{{"
            ],
            outdent: [
                ")",
                "}",
                "}}"
            ],
            whitespaceDenotesBlocks: true)
    }
}
