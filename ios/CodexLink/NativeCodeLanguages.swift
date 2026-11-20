import Foundation
import Runestone
import RunestoneLanguageSupport

/// One catalog for filenames, fenced code blocks, previews and embedded languages.
enum NativeCodeLanguages {
    private struct Entry {
        let name: String
        let aliases: [String]
        var make: (() -> TreeSitterLanguage)? = nil
        var tokenizer: String? = nil
    }
    private static let entries: [Entry] = [
        Entry(name: "agda", aliases: ["agda"], tokenizer: "agda"),
        Entry(name: "astro", aliases: ["astro"], make: { .astro }),
        Entry(name: "bash", aliases: ["bash", "sh", "zsh", "shell", "shellscript", "command", "dotenv", "env"], make: { .bash }),
        Entry(name: "bicep", aliases: ["bicep", "bicepparam"], tokenizer: "bicep"),
        Entry(name: "c", aliases: ["c", "h"], make: { .c }),
        Entry(name: "cmake", aliases: ["cmake"], make: { .cmake }),
        Entry(name: "cpp", aliases: ["cpp", "c++", "cc", "cxx", "hpp", "hxx", "hh", "ipp", "tpp", "ixx", "cppm"], make: { .cpp }),
        Entry(name: "css", aliases: ["css"], make: { .css }),
        Entry(name: "csharp", aliases: ["csharp", "c#", "cs", "csx"], make: { .cSharp }),
        Entry(name: "comment", aliases: ["comment"], make: { .comment }),
        Entry(name: "dart", aliases: ["dart"], tokenizer: "dart"),
        Entry(name: "diff", aliases: ["diff", "patch"], make: { .diff }),
        Entry(name: "dockerfile", aliases: ["dockerfile", "containerfile", "docker"], make: { .dockerfile }),
        Entry(name: "elixir", aliases: ["elixir", "ex", "exs"], tokenizer: "elixir"),
        Entry(name: "elm", aliases: ["elm"], tokenizer: "elm"),
        Entry(name: "fish", aliases: ["fish"], make: { .fish }),
        Entry(name: "glimmer", aliases: ["glimmer", "hbs", "handlebars", "mustache"], make: { .glimmer }),
        Entry(name: "go", aliases: ["go", "golang"], make: { .go }),
        Entry(name: "gomod", aliases: ["gomod", "go-mod", "go.mod"], make: { .goMod }),
        Entry(name: "hcl", aliases: ["hcl", "terraform", "tf", "tfvars"], make: { .hcl }),
        Entry(name: "html", aliases: ["html", "htm"], make: { .html }),
        Entry(name: "haskell", aliases: ["haskell", "hs"], tokenizer: "haskell"),
        Entry(name: "jsdoc", aliases: ["jsdoc"], make: { .jsDoc }),
        Entry(name: "json", aliases: ["json", "jsonl", "ndjson"], make: { .json }),
        Entry(name: "json5", aliases: ["json5", "jsonc"], make: { .json5 }),
        Entry(name: "java", aliases: ["java"], make: { .java }),
        Entry(name: "javascript", aliases: ["javascript", "js", "mjs", "cjs"], make: { .javaScript }),
        Entry(name: "julia", aliases: ["julia", "jl"], tokenizer: "julia"),
        Entry(name: "kotlin", aliases: ["kotlin", "kt", "kts"], make: { .kotlin }),
        Entry(name: "latex", aliases: ["latex", "tex", "sty", "cls"], tokenizer: "latex"),
        Entry(name: "lua", aliases: ["lua"], make: { .lua }),
        Entry(name: "markdown", aliases: ["markdown", "md", "mdown"], make: { .markdown }),
        Entry(name: "markdown_inline", aliases: ["markdown_inline", "markdown-inline", "markdowninline"], make: { .markdownInline }),
        Entry(name: "nix", aliases: ["nix"], make: { .nix }),
        Entry(name: "ocaml", aliases: ["ocaml", "ml"], tokenizer: "ocaml"),
        Entry(name: "ocaml_interface", aliases: ["ocaml_interface", "ocaml-interface", "ocamlinterface", "mli"], tokenizer: "ocaml"),
        Entry(name: "objective-c", aliases: ["objective-c", "objectivec", "objc", "obj-c", "m", "mm"], make: { .objectiveC }),
        Entry(name: "php", aliases: ["php", "phtml"], make: { .php }),
        Entry(name: "pascal", aliases: ["pascal", "pas", "pp", "lpr"], tokenizer: "pascal"),
        Entry(name: "perl", aliases: ["perl", "pl", "pm"], tokenizer: "perl"),
        Entry(name: "proto", aliases: ["proto", "protobuf"], make: { .proto }),
        Entry(name: "python", aliases: ["python", "py", "pyw", "pyi"], make: { .python }),
        Entry(name: "r", aliases: ["r"], tokenizer: "r"),
        Entry(name: "regex", aliases: ["regex", "regexp"], make: { .regex }),
        Entry(name: "ruby", aliases: ["ruby", "rb", "rake", "gemspec"], make: { .ruby }),
        Entry(name: "rust", aliases: ["rust", "rs"], make: { .rust }),
        Entry(name: "scss", aliases: ["scss"], make: { .scss }),
        Entry(name: "pgsql", aliases: ["pgsql", "postgresql", "postgres", "plpgsql"], tokenizer: "pgsql"),
        Entry(name: "sql", aliases: ["sql"], tokenizer: "sql"),
        Entry(name: "scala", aliases: ["scala", "sc", "sbt"], tokenizer: "scala"),
        Entry(name: "svelte", aliases: ["svelte"], make: { .svelte }),
        Entry(name: "swift", aliases: ["swift"], make: { .swift }),
        Entry(name: "toml", aliases: ["toml"], make: { .toml }),
        Entry(name: "tsx", aliases: ["tsx"], make: { .tsx }),
        Entry(name: "typescript", aliases: ["typescript", "ts", "mts", "cts"], make: { .typeScript }),
        Entry(name: "verilog", aliases: ["verilog", "v", "vh", "sv", "svh", "systemverilog", "system-verilog"], tokenizer: "verilog"),
        Entry(name: "xml", aliases: ["xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib", "entitlements", "xcprivacy", "csproj", "fsproj", "vbproj", "props", "targets", "config"], make: { .xml }),
        Entry(name: "yaml", aliases: ["yaml", "yml"], make: { .yaml }),
        Entry(name: "zig", aliases: ["zig", "zon"], tokenizer: "zig"),
        Entry(name: "jsx", aliases: ["jsx"], make: { .jsx })
    ]
    private static let byAlias: [String: Entry] = Dictionary(uniqueKeysWithValues:
        entries.flatMap { entry in entry.aliases.map { ($0, entry) } })
    static var supportedNames: [String] { entries.map(\.name) }

    static func name(_ hint: String) -> String {
        let hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (hint as NSString).lastPathComponent.lowercased()
        if filename == "cmakelists.txt" { return "cmake" }
        if filename == "go.mod" { return "gomod" }
        if ["gemfile", "rakefile", "podfile", "brewfile", "vagrantfile"].contains(filename) { return "ruby" }
        if [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile", ".env"].contains(filename)
            || filename.hasPrefix(".env.") { return "bash" }
        if filename == "dockerfile" || filename == "containerfile"
            || filename.hasPrefix("dockerfile.") || filename.hasPrefix("containerfile.") { return "dockerfile" }
        if let entry = byAlias[hint.lowercased()] { return entry.name }
        let suffix = (hint as NSString).pathExtension.lowercased()
        return byAlias[suffix]?.name ?? "text"
    }

    // Each call creates independent lazy queries and parser state for its editor.
    static func language(_ hint: String) -> TreeSitterLanguage? {
        byAlias[name(hint)]?.make?()
    }

    static func tokenizer(_ hint: String) -> String? {
        byAlias[name(hint)]?.tokenizer
    }
}

final class NativeCodeLanguageProvider: TreeSitterLanguageProvider {
    func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        NativeCodeLanguages.language(languageName)
    }
}
