import Runestone

public extension TreeSitterIndentationScopes {
    static var goMod: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "("
            ],
            outdent: [
                ")"
            ],
            whitespaceDenotesBlocks: true)
    }
}
