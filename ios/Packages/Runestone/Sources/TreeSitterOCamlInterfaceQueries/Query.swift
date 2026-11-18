import Foundation
import TreeSitterOCamlQueries

/// OCaml implementation and interface grammars share query resources.
public enum Query {
    public static var foldsFileURL: URL? {
        TreeSitterOCamlQueries.Query.foldsFileURL
    }

    public static var highlightsFileURL: URL {
        TreeSitterOCamlQueries.Query.highlightsFileURL
    }

    public static var localsFileURL: URL {
        TreeSitterOCamlQueries.Query.localsFileURL
    }

    public static var tagsFileURL: URL {
        TreeSitterOCamlQueries.Query.tagsFileURL
    }

}
