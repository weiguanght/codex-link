import Foundation

public enum Query {
    /// Optional folding rules; returns nil when no rules are bundled.
    public static var foldsFileURL: URL? {
        Bundle.module.url(forResource: "folds", withExtension: "scm")
    }

    public static var highlightsFileURL: URL {
        Bundle.module.url(forResource: "highlights", withExtension: "scm")!
    }
}
