#if LINK_SMOKE
import SwiftUI
import Runestone

/// Execute representative upstream fixtures through the actual iOS highlighter.
enum NativeSyntaxSmoke {
    private struct Fixture {
        let language: String
        let source: String
        let captures: [(String, String)]
    }
    private static let fixtures: [Fixture] = [
        Fixture(language: "agda", source: "module Example where\n\n-- identity\nidentity : {A : Set} → A → A\nidentity x = x\n", captures: [("keyword", "module"), ("keyword", "where"), ("keyword", "Set"), ("comment", "-- identity")]),
        Fixture(language: "bicep", source: "param name string = 'hello'\nvar count = 42\n// comment\n", captures: [("keyword", "param"), ("string", "'hello'"), ("number", "42")]),
        Fixture(language: "cmake", source: "cmake_minimum_required(VERSION 3.20)\nproject(Example)\nset(NAME \"hello\")\ncustom(value)\n# comment\n", captures: [("function.builtin", "project"), ("string", "\"hello\""), ("comment", "# comment")]),
        Fixture(language: "dart", source: "void main() { final count = 42; print(\"hello\"); }\n", captures: [("keyword", "final"), ("number", "42"), ("string", "\"hello\""), ("function.definition", "main"), ("function.call", "print")]),
        Fixture(language: "dockerfile", source: "FROM alpine:3.20 AS base\n# Build image\nENV APP_HOME=\"/app\"\nWORKDIR /app\nRUN echo \"hello\"\nCMD [\"echo\", \"ready\"]\n", captures: [("keyword", "FROM"), ("keyword", "RUN"), ("keyword", "CMD"), ("comment", "# Build image"), ("string", "\"ready\"")]),
        Fixture(language: "fish", source: "function greet\n  echo \"hello\"\n  test 1 -eq 1\nend\n# note\n", captures: [("keyword", "function"), ("function", "greet"), ("string", "\"hello\""), ("operator", "-eq"), ("comment", "# note")]),
        Fixture(language: "glimmer", source: "<Widget @name=\"Ada\" />\n<div>{{this.name}}</div>\n{{#if ready}}yes{{else}}no{{/if}}\n", captures: [("constructor", "Widget"), ("tag", "div"), ("variable.builtin", "this"), ("conditional", "if")]),
        Fixture(language: "goMod", source: "module example.com/demo\n\ngo 1.22\n\n// Dependencies\nrequire (\n  example.com/alpha v1.2.3\n  example.com/beta v2.0.0 // indirect\n)\nreplace example.com/alpha => ../alpha\n", captures: [("keyword", "module"), ("keyword", "require"), ("keyword", "replace"), ("operator", "=>"), ("string", "v1.2.3"), ("comment", "// Dependencies")]),
        Fixture(language: "hcl", source: "resource \"example\" \"demo\" {\n count = 42\n enabled = true\n}\n# comment\n", captures: [("keyword", "resource"), ("number", "42"), ("constant.builtin", "true")]),
        Fixture(language: "jsx", source: "const view = <section title=\"Hello\">{name}<Widget enabled={true} /></section>;", captures: [("keyword", "const"), ("tag", "section"), ("attribute", "title"), ("string", "\"Hello\""), ("attribute", "enabled")]),
        Fixture(language: "kotlin", source: "package example\nclass Stringish\n// Greeting\nfun greet(name: String): String {\n  val count: Int = 42\n  println(name)\n  val message = greet(name)\n  val custom: Stringish? = null\n  return \"hello\"\n}\n", captures: [("keyword", "fun"), ("function", "greet"), ("type.builtin", "String"), ("type.builtin", "Int"), ("number", "42"), ("function.builtin", "println"), ("string", "\"hello\""), ("comment", "// Greeting"), ("type", "Stringish")]),
        Fixture(language: "ocamlInterface", source: "(** Public interface *)\nmodule Example : sig\n  type t\n  val count : t -> int\n  val name : string\nend\n(* outer (* nested *) comment *)\n", captures: [("keyword", "module"), ("keyword", "sig"), ("keyword", "val"), ("keyword", "type"), ("comment", "(* outer (* nested *) comment *)")]),
        Fixture(language: "objectiveC", source: "@interface Example\n- (int)answer;\n@end\n@implementation Example\n- (int)answer { id value = @\"hello\"; return 42; }\n@end\n", captures: [("keyword", "@interface"), ("keyword", "return"), ("number", "42"), ("string", "@\"hello\""), ("function.method", "answer")]),
        Fixture(language: "pascal", source: "program Example;\nvar value: Integer;\nbegin\n  value := 42;\n  WriteLn('hello');\nend.\n", captures: [("keyword", "begin"), ("number", "42"), ("string", "'hello'"), ("function.call", "WriteLn")]),
        Fixture(language: "proto", source: "syntax = \"proto3\";\nmessage Greeting { string name = 1; }\n// comment\n", captures: [("keyword.type", "message"), ("string", "\"proto3\""), ("number", "1"), ("comment", "// comment")]),
        Fixture(language: "scala", source: "object Main { val count = 42; val message = \"hello\" }\n", captures: [("keyword", "val"), ("number", "42"), ("string", "\"hello\"")]),
        Fixture(language: "verilog", source: "// Combinational circuit\nmodule example(input wire a, output wire b);\n  parameter WIDTH = 8;\n  always_ff @(posedge a) count <= 8'hFF;\n  assign b = a;\n  initial $display(\"hello\");\nendmodule\n", captures: [("keyword", "module"), ("keyword", "endmodule"), ("keyword", "assign"), ("keyword", "always_ff"), ("number", "8'hFF"), ("number", "8"), ("string", "\"hello\""), ("comment", "// Combinational circuit")]),
        Fixture(language: "zig", source: "//! Module docs\nconst std = @import(\"std\");\n// Entry point\npub fn main() void {\n    const count: u32 = 42;\n    const ratio: f64 = 3.14;\n    _ = count;\n    _ = ratio;\n}\n", captures: [("keyword", "fn"), ("function", "main"), ("type.builtin", "u32"), ("number", "42"), ("number", "3.14"), ("string", "\"std\""), ("comment", "// Entry point"), ("comment.documentation", "//! Module docs")]),
        Fixture(language: "astro", source: "---\nconst title: string = \"Hello\";\n---\n<html><h1 class=\"hero\">{title}</h1><Card count={2} /><style>.hero {color: red}</style></html>\n", captures: [("tag", "h1"), ("attribute", "class"), ("string", "hero"), ("punctuation.bracket", "{")]),
        Fixture(language: "bash", source: "#!/usr/bin/env bash\nset -euo pipefail\nname=\"world\"\ngreet() {\n  local value=\"${name^^}\"\n  if [[ -n \"$value\" ]]; then\n    printf '%s\\n' \"$value\"\n  fi\n}\nfor file in *.txt; do greet \"$file\"; done\ncat <<EOF\nHello $name\nEOF\n# normal comment\n", captures: [("keyword", "if"), ("keyword", "for"), ("function", "greet"), ("property", "name"), ("string", "'%s\\n'"), ("comment", "# normal comment")]),
        Fixture(language: "c", source: "// C23 declarations and ordinary C calls\nconstexpr int LIMIT = 4;\nstruct Point { int value; };\nint compute(int value) { const char *message = \"hello\"; return value + LIMIT; }\n", captures: [("keyword", "constexpr"), ("keyword", "return"), ("function.definition", "compute"), ("string", "\"hello\""), ("number", "4"), ("constant", "LIMIT")]),
        Fixture(language: "cpp", source: "// Concepts, constraints, and raw literals\n#include <string>\ntemplate<typename T> concept Sized = requires(T x) { x.size(); };\nconstexpr int LIMIT = 4;\nint compute(int value) { auto text = R\"(hello)\"; return value + LIMIT; }\n", captures: [("keyword", "concept"), ("keyword", "requires"), ("keyword", "constexpr"), ("function.definition", "compute"), ("string", "R\"(hello)\""), ("number", "4")]),
        Fixture(language: "css", source: "/* layout */\n@layer components {\n.card { --accent: #f00; color: var(--accent); &:hover { display: grid; gap: 1.5rem; } }\n}\n@container (min-width: 30rem) { .card { padding: 2rem; } }\n", captures: [("comment", "/* layout */"), ("property", "card"), ("variable", "--accent"), ("function", "var"), ("number", "1.5rem"), ("type", "rem"), ("punctuation.bracket", "{")]),
        Fixture(language: "cSharp", source: "// Raw literals and collection expressions\nclass Example {\n string text = \"\"\"hello\"\"\";\n int[] values = [1, 2, 3];\n string Format(int value) => $\"Value {value + 1}\";\n int Compute(int value) { return value + values.Length; }\n}\n", captures: [("keyword", "class"), ("keyword", "return"), ("function.definition", "Compute"), ("string", "\"\"\"hello\"\"\""), ("number", "3"), ("none", "{value + 1}")]),
        Fixture(language: "comment", source: "TODO(alice): finish parser #123 and @bob\nFIXME: handle nested comments\nNOTE: this is ordinary text\nhttps://example.com/docs\n", captures: [("text.warning", "TODO"), ("text.danger", "FIXME"), ("constant", "alice"), ("number", "#123"), ("constant", "@bob")]),
        Fixture(language: "diff", source: "diff --git a/demo.txt b/demo.txt\nindex 1234567..abcdef0 100644\n--- a/demo.txt\n+++ b/demo.txt\n@@ -1,3 +1,3 @@\n context æøå\n-old value\n+new value\n---old marker\n+++new marker\n\\ No newline at end of file\n!changed\n# comment\ndiff --git a/image.bin b/image.bin\nindex 1111111..2222222 100644\nGIT binary patch\nliteral 1\nA00000\n\nliteral 1\nB11111\n\n", captures: [("diff.plus", "+new value"), ("diff.minus", "-old value"), ("diff.plus", "+++new marker"), ("diff.minus", "---old marker"), ("diff.plus", "+++ b/demo.txt"), ("diff.minus", "--- a/demo.txt"), ("attribute", "@@ -1,3 +1,3 @@"), ("constant", "1234567"), ("number", "100644"), ("punctuation.special", ".."), ("string.special.path", "b/demo.txt"), ("diff.delta", "!changed"), ("comment", "# comment"), ("diff.plus", "A00000"), ("diff.minus", "B11111")]),
        Fixture(language: "elixir", source: "defmodule Example do\n  @moduledoc \"Utilities\"\n  @spec greet(String.t()) :: String.t()\n  def greet(name) when is_binary(name) do\n    message = \"Hello #{name}\"\n    Enum.map([1, 2, 3], fn value -> value * 2 end)\n    {:ok, message, true, nil}\n  end\nend\n# normal comment\n", captures: [("keyword.elixir", "defmodule"), ("keyword.elixir", "def"), ("number", "2"), ("constant.builtin", "true"), ("constant.builtin", "nil"), ("comment", "# normal comment")]),
        Fixture(language: "elm", source: "module Main exposing (Model, update)\nimport Html exposing (text)\ntype alias Model = { count : Int }\ntype Msg = Increment | Reset\nupdate msg model =\n    case msg of\n        Increment -> { model | count = model.count + 1 }\n        Reset -> { model | count = 0 }\nmain = text \"Hello\"\n-- normal comment\n", captures: [("keyword.other.elm", "module"), ("keyword.control.elm", "case"), ("number", "1"), ("constructor", "Increment"), ("string.elm", "Hello"), ("comment.elm", "-- normal comment")]),
        Fixture(language: "go", source: "package example\n// Generic type aliases\ntype Set[P comparable] = map[P]bool\nfunc compute(value int) string {\n values := []int{1, 42}\n println(len(values))\n return \"hello\"\n}\n", captures: [("keyword", "type"), ("keyword", "func"), ("keyword", "return"), ("function.definition", "compute"), ("function.builtin", "len"), ("number", "42"), ("string", "\"hello\"")]),
        Fixture(language: "html", source: "<!DOCTYPE html>\n<!-- page -->\n<main class=\"card\"><h1>Hello &amp; bye</h1><input disabled /></main>\n<script type=\"module\">const count = 2;</script>\n<script type=\"application/ld+json\">{\"name\":\"Ada\"}</script>\n<style>.card { color: red; }</style>\n", captures: [("tag", "main"), ("attribute", "disabled"), ("string", "card"), ("comment", "<!-- page -->"), ("punctuation.bracket", "/>")]),
        Fixture(language: "haskell", source: "{-# LANGUAGE GHC2021 #-}\nmodule Example where\nimport Data.List (sort)\ndata Result a = Success a | Failure String\ncount :: [Int] -> Int\ncount values = length [x | x <- values, x > 0]\nmain :: IO ()\nmain = do\n  let result = Success (count [1, 2, 3])\n  if True then print \"ready\" else pure ()\n-- normal comment\n", captures: [("keyword.import", "module"), ("keyword.import", "import"), ("keyword.conditional", "if"), ("number", "3"), ("string", "\"ready\""), ("comment", "-- normal comment")]),
        Fixture(language: "jsDoc", source: "/**\n * Build a greeting.\n * @param {string} name Person to greet.\n * @param {Array<number>} values Input values.\n * @returns {Promise<string>} The greeting.\n * @deprecated Use greetAsync instead.\n */\n", captures: [("keyword", "@param"), ("keyword", "@returns"), ("type", "string"), ("type", "Array<number>")]),
        Fixture(language: "json", source: "{\"name\":\"Ada\",\"active\":true,\"items\":[1,null,2.5],\"escape\":\"a\\nb\"}\n", captures: [("string.special.key", "\"name\""), ("string", "\"Ada\""), ("constant.builtin", "true"), ("constant.builtin", "null"), ("number", "2.5"), ("escape", "\\n")]),
        Fixture(language: "json5", source: "// configuration\n{unquoted: \"value\", single: 'yes', list: [true, null, 0xFF, Infinity, NaN,],}\n", captures: [("comment", "// configuration"), ("property", "unquoted"), ("string", "'yes'"), ("number", "0xFF"), ("number", "Infinity"), ("constant.builtin", "true"), ("constant.builtin", "null")]),
        Fixture(language: "java", source: "// Guarded patterns and text blocks\nclass Example {\n String text = \"\"\"\nhello\n\"\"\";\n static int compute(Object value) { return switch (value) {\n case String s when !s.isEmpty() -> s.length(); default -> 42; }; }\n}\n", captures: [("keyword", "when"), ("keyword", "switch"), ("keyword", "return"), ("function.method", "compute"), ("number", "42"), ("string", "\"\"\"\nhello\n\"\"\"")]),
        Fixture(language: "javaScript", source: "/** Example function. */\nconst LIMIT = 42;\nclass Example { #value = 1; compute(value) { return `Hello ${value + LIMIT}`; } }\nfunction greet(value) { let console = value; return console; }\nconst pattern = /hello+/gi;\nconst markup = html`<b>Hello</b>`;\n", captures: [("keyword", "const"), ("keyword", "return"), ("function.definition", "greet"), ("function.method", "compute"), ("number", "42"), ("none", "${value + LIMIT}"), ("string", "`Hello ${value + LIMIT}`")]),
        Fixture(language: "julia", source: "module Example\npublic greet\nstruct Person\n    name::String\nend\nfunction greet(person::Person, values::Vector{Int})\n    selected = values[begin:end]\n    message = \"Hello $(person.name)\"\n    kind = typeof(person)\n    return sum(x^2 for x in selected if x > 0), true, nothing\nend\n# normal comment\nend\n", captures: [("keyword", "struct"), ("keyword", "function"), ("keyword", "return"), ("constant", "true"), ("constant", "nothing"), ("keyword", "begin")]),
        Fixture(language: "latex", source: "\\documentclass{article}\n\\usepackage{amsmath}\n\\title{A study}\n\\begin{document}\n\\section{Introduction}\nSome \\emph{italic} and \\textbf{bold} text. See \\ref{sec:intro}.\n\\label{sec:intro}\n\\[ x^2 + y^2 = z^2 \\]\n% example\n\\begin{minted}{python}\nprint(\"hello\")\n\\end{minted}\nPrice: 95\\% of total.\n\\begin{verbatim}a% b\\end{verbatim}\n\\end{document}\n\\url{https://example.com}\n", captures: [("keyword", "\\documentclass"), ("comment", "% example"), ("keyword", "\\%"), ("string", "a% b")]),
        Fixture(language: "lua", source: "-- Attributes, long strings, methods and builtins\nlocal LIMIT <const> = 42\nlocal message = [=[hello]=]\nlocal object = {}\nfunction object:compute(value)\n print(message)\n return value + LIMIT\nend\nobject:compute(1)\n", captures: [("keyword", "local"), ("keyword.return", "return"), ("function.method", "compute"), ("function.method.call", "compute"), ("function.builtin", "print"), ("number", "42"), ("string", "[=[hello]=]"), ("attribute", "const")]),
        Fixture(language: "markdown", source: "# Heading\n\n> A quote with **strong** text.\n\n- [x] task\n\n```python\nprint(\"hello\")\n```\n\n| Name | Count |\n| --- | --- |\n| Ada | 2 |\n", captures: [("text.title", "Heading"), ("punctuation.special", "#"), ("punctuation.delimiter", "```"), ("punctuation.special", "> "), ("punctuation.special", "- "), ("punctuation.special", "[x]")]),
        Fixture(language: "markdownInline", source: "Text *emphasis* and **strong**, `code`, [site](https://example.com), ![image](image.png), ~~old~~ and $x^2$.", captures: [("text.emphasis", "*emphasis*"), ("text.strong", "**strong**"), ("text.literal", "`code`"), ("text.uri", "https://example.com"), ("text.reference", "image"), ("punctuation.delimiter", ")"), ("text.strike", "~~old~~")]),
        Fixture(language: "ocaml", source: "module Example = struct\n  type result = Success of int | Failure of string\n  let count values = List.fold_left (fun total value -> total + value) 0 values\n  let describe = function\n    | Success value -> Printf.sprintf \"value=%d\" value\n    | Failure message -> message\nend\n(* outer (* nested *) comment *)\n", captures: [("keyword", "module"), ("keyword", "type"), ("keyword", "let"), ("keyword", "function"), ("number", "0"), ("string", "\"value=%d\""), ("comment", "(* outer (* nested *) comment *)")]),
        Fixture(language: "php", source: "<p>Hello</p>\n<?php\n// PHP 8.4 property hooks\nclass User { public string $name { get => \"Alice\"; }\n public function compute(int $value): int { return $value + 42; }\n}\n$name = \"hello\";\n", captures: [("keyword", "get"), ("keyword", "class"), ("keyword", "return"), ("function.method", "compute"), ("string", "\"Alice\""), ("number", "42"), ("type.builtin", "string")]),
        Fixture(language: "perl", source: "use v5.40;\nuse strict;\nuse warnings;\npackage Example;\nsub greet ($name) {\n    my @values = (1, 2, 3);\n    my $message = \"Hello $name\";\n    if ($name =~ /world/i) { say $message; }\n    return [map { $_ * 2 } @values];\n}\n# normal comment\n", captures: [("keyword.import", "use"), ("keyword.function", "sub"), ("keyword", "my"), ("keyword.conditional", "if"), ("keyword.return", "return"), ("number", "3"), ("comment", "# normal comment")]),
        Fixture(language: "python", source: "# Python 3.12 aliases, generic definitions and interpolation\ntype Point = tuple[float, float]\ndef identity[T](value: T) -> T:\n    message = f\"hello {value}\"\n    print(message, 42)\n    return value\n", captures: [("keyword", "type"), ("keyword", "def"), ("keyword", "return"), ("function.definition", "identity"), ("function.builtin", "print"), ("number", "42"), ("none", "{value}"), ("string", "f\"hello {value}\"")]),
        Fixture(language: "r", source: "library(stats)\ntransform_values <- function(values, scale = 2) {\n  result <- values |> sqrt() |> round(digits = 2)\n  if (length(result) > 0) return(result * scale)\n  NULL\n}\ntext <- r\"(raw \\ string)\"\nmapper <- \\(x) x + 1\nflag <- TRUE\n# normal comment\n", captures: [("keyword.function", "function"), ("keyword.conditional", "if"), ("keyword.return", "return"), ("constant.builtin", "NULL"), ("constant.builtin", "TRUE"), ("number", "2"), ("comment", "# normal comment")]),
        Fixture(language: "regex", source: "^(?<name>[A-Za-z_][A-Za-z0-9_]*)(?:\\s+|,)(foo|bar){2,4}\\p{L}+$", captures: [("escape", "^"), ("escape", "$"), ("operator", "+"), ("number", "2"), ("number", "4")]),
        Fixture(language: "ruby", source: "# Endless methods, interpolation and heredocs\nclass Example\n  LIMIT = 42\n  def compute(value) = \"hello #{value}\"\n  def message\n    <<~TEXT\nhello\nTEXT\n  end\nend\nexample = Example.new\nexample.compute(1)\n", captures: [("keyword", "class"), ("keyword", "def"), ("function.method", "compute"), ("number", "42"), ("constant", "LIMIT"), ("string", "\"hello #{value}\""), ("none", "#{value}")]),
        Fixture(language: "rust", source: "// Async functions and macro token trees\nconst LIMIT: usize = 42;\nasync fn compute(value: usize) -> usize {\n let message = r#\"hello\"#;\n println!(\"{}\", message);\n value + LIMIT\n}\n", captures: [("keyword", "async"), ("keyword", "fn"), ("function.definition", "compute"), ("string", "r#\"hello\"#"), ("number", "42"), ("constant", "LIMIT")]),
        Fixture(language: "scss", source: "$space: 1rem;\n// reusable layout\n@mixin card($gap) { padding: $gap; &:hover { color: #fff; } }\n.card { @include card($space); }\n", captures: [("variable", "$space"), ("keyword", "@mixin"), ("keyword", "@include"), ("comment", "// reusable layout"), ("property", "padding"), ("string.special", "#fff")]),
        Fixture(language: "pgsql", source: "-- 中文😀\r\nCREATE FUNCTION f() RETURNS TEXT LANGUAGE plpgsql AS $$ BEGIN RETURN 'ok'; END; $$;\n", captures: [("comment", "-- 中文😀"), ("keyword", "CREATE"), ("keyword", "RETURN"), ("string", "'ok'")]),
        Fixture(language: "sql", source: "WITH ranked AS (\n  SELECT u.id, u.name, ROW_NUMBER() OVER (PARTITION BY u.team ORDER BY u.score DESC) AS rank\n  FROM users AS u WHERE u.active = TRUE AND u.score >= 1.5\n)\nSELECT id, name FROM ranked WHERE rank = 1 ORDER BY name;\nCREATE TABLE events (id BIGINT PRIMARY KEY, payload JSONB, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);\n-- normal comment\nSELECT 1e3, '123', 42;\n", captures: [("keyword", "SELECT"), ("keyword", "FROM"), ("keyword", "WHERE"), ("constant.builtin", "TRUE"), ("number.float", "1.5"), ("comment", "-- normal comment"), ("number.float", "1e3"), ("number.integer", "42"), ("string", "'123'"), ("function.call", "ROW_NUMBER")]),
        Fixture(language: "svelte", source: "<script lang=\"ts\" type=\"text/javascript\">let count: number = 1;</script>\n<style lang=\"scss\">$color: red; p { color: $color; }</style>\n{#snippet greeting(name)}<p class=\"greeting\">Hello {name}</p>{/snippet}\n{@render greeting(\"Ada\")}\n{#if count > 0}<strong>Active</strong>{:else}<em>Empty</em>{/if}\n", captures: [("keyword", "snippet"), ("keyword", "render"), ("function", "greeting"), ("keyword.conditional", "if"), ("tag", "p"), ("string", "\"greeting\""), ("text.strong", "Active")]),
        Fixture(language: "swift", source: "// Swift 6 isolation and ordinary syntax\nnonisolated(unsafe) var cache: Int = 0\nstruct Example {\n var value: Int = 42\n func compute(_ input: Int) async -> String {\n   let greeting = \"hello\"\n   return greeting\n }\n}\n", captures: [("keyword", "var"), ("keyword.function", "func"), ("keyword.coroutine", "async"), ("function.method", "compute"), ("keyword.return", "return"), ("string", "hello"), ("number", "42"), ("keyword.modifier", "nonisolated(unsafe)")]),
        Fixture(language: "toml", source: "# application\n[server.http]\nport = 8080\nenabled = true\nstarted = 2026-10-25T10:15:00Z\nlabels = { owner = \"Ada\", region = \"eu\" }\n[[routes]]\npath = \"/\"\n", captures: [("comment", "# application"), ("property", "port"), ("number", "8080"), ("boolean", "true"), ("string.special", "2026-10-25T10:15:00Z"), ("string", "\"Ada\"")]),
        Fixture(language: "tsx", source: "// Typed JSX and const generic arrow functions\nfunction identity<const T>(value: T): T { return value; }\nconst title: string = \"hello\";\nconst view = <div data-count={42}><Widget title={title} /></div>;\n", captures: [("keyword", "const"), ("function.definition", "identity"), ("tag", "div"), ("string", "\"hello\""), ("number", "42"), ("type.builtin", "string")]),
        Fixture(language: "typeScript", source: "// Const type parameters and satisfies\nfunction identity<const T>(value: T): T { return value; }\nconst options = {name: \"hello\", count: 42} satisfies {name: string; count: number};\n", captures: [("keyword", "satisfies"), ("keyword", "return"), ("function.definition", "identity"), ("variable.parameter", "value"), ("string", "\"hello\""), ("number", "42")]),
        Fixture(language: "yaml", source: "---\n# deployment\ndefaults: &base\n  enabled: true\n  retries: 3\nservice:\n  <<: *base\n  tags: [web, \"api\"]\n  metadata: {owner: Ada, active: false}\n  script: |\n    echo hello\n    echo done\n", captures: [("comment", "# deployment"), ("field", "defaults"), ("type", "base"), ("boolean", "true"), ("number", "3"), ("string", "web"), ("string", "Ada"), ("string", "|\n    echo hello\n    echo done\n")]),
        Fixture(language: "xml", source: "<?xml version=\"1.0\"?><root name=\"test\"><child>Hello &amp; &custom;</child><![CDATA[<literal> & text]]><!-- comment --></root>\n", captures: [("comment", "<!-- comment -->"), ("constant", "&custom;"), ("constant.builtin", "&amp;"), ("property", "name"), ("punctuation.delimiter", "<![CDATA["), ("punctuation.delimiter", "]]>"), ("string", "\"test\""), ("tag", "child"), ("tag", "root"), ("text.literal", "<literal> & text")]),
        Fixture(language: "nix", source: "# comment\n{ pkgs }: let count = 42; in { hello = pkgs.hello; enabled = true; value = builtins.toString count; custom = pkgs; }\n", captures: [("comment", "# comment"), ("keyword", "let"), ("number", "42"), ("variable.builtin", "builtins"), ("variable.builtin", "true")])
    ]
    static func verify() throws -> Int {
        guard NativeSendMode.followUp(nil) == "queue", NativeSendMode.followUp("send") == "queue",
              NativeSendMode.followUp("queue") == "queue", NativeSendMode.followUp("steer") == "steer",
              NativeSendMode.resolve("queue", running: true) == "queue",
              NativeSendMode.resolve("steer", running: true) == "steer",
              NativeSendMode.resolve("queue", running: false) == "send",
              NativeSendMode.resolve("steer", running: false) == "send" else {
            throw LinkError.message("Invalid follow-up mode migration or idle sending")
        }
        let theme = NativeCodeTheme()
        var failures: [String] = []
        let tested = Set(fixtures.map { NativeCodeLanguages.name($0.language) })
        guard tested == Set(NativeCodeLanguages.supportedNames) else {
            throw LinkError.message("Language fixture coverage missing: " + Set(NativeCodeLanguages.supportedNames).subtracting(tested).sorted().joined(separator: ", "))
        }
        for fixture in fixtures {
            let lexical = NativeCodeLanguages.tokenizer(fixture.language) != nil
            guard lexical || NativeCodeLanguages.language(fixture.language)?.highlightsQuery != nil else {
                failures.append("Missing grammar: " + fixture.language); continue
            }
            let result = NativeSyntaxHighlight.native(fixture.source, language: fixture.language, theme: theme)
            guard result.string == fixture.source else { throw LinkError.message("Syntax highlighting changed text: " + fixture.language) }
            let samples = fixture.captures.filter { theme.textColor(for: $0.0) != nil }
            guard let first = samples.first else {
                failures.append("Missing colored fixture: " + fixture.language); continue
            }
            for sample in lexical ? samples : [first] {
                let source = fixture.source as NSString
                var search = NSRange(location: 0, length: source.length)
                var matched = false
                while search.length > 0 {
                    let range = source.range(of: sample.1, range: search)
                    if range.location == NSNotFound { break }
                    if let color = result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor,
                       color.isEqual(theme.textColor(for: sample.0)) { matched = true; break }
                    search = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
                }
                if !matched { failures.append("Uncolored syntax: " + fixture.language + " / " + sample.1) }
            }
        }
        if !failures.isEmpty { throw LinkError.message(failures.joined(separator: "; ")) }
        for (hint, expected) in [
            ("Sources/example.cpp", "cpp"), ("Header.hpp", "cpp"), ("Controller.m", "objective-c"),
            ("go.mod", "gomod"), ("build/CMakeLists.txt", "cmake"), ("Dockerfile.dev", "dockerfile"),
            (".env.local", "bash"), ("Gemfile", "ruby"), ("config.jsonc", "json5"), ("Info.plist", "xml"),
            ("Component.jsx", "jsx"), ("Component.tsx", "tsx"), ("c++", "cpp"), ("c#", "csharp"),
            ("config.toml", "toml"), ("unknown.bin", "text"), ("controller.svh", "verilog"), ("chapter.sty", "latex"),
            ("library.mli", "ocaml_interface"), ("postgresql", "pgsql")
        ] {
            guard NativeCodeLanguages.name(hint) == expected else { throw LinkError.message("Wrong grammar: " + hint) }
        }
        let embedded = "<script>const answer = 42;</script>"
        let highlighted = StringSyntaxHighlighter(theme: theme, language: NativeCodeLanguages.language("html")!, languageProvider: NativeCodeLanguageProvider()).syntaxHighlight(embedded)
        let keyword = (embedded as NSString).range(of: "const")
        guard (highlighted.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? UIColor)?.isEqual(UIColor.systemPurple) == true else {
            throw LinkError.message("Embedded JavaScript did not highlight")
        }
        return fixtures.count
    }
}
#endif

#if LINK_SMOKE && LINK_SYNTAX_ONLY
@main
struct NativeSyntaxSmokeApp: App {
    var body: some Scene { WindowGroup { NativeSyntaxSmokeScreen() } }
}

private struct NativeSyntaxSmokeScreen: View {
    @State private var content = "# test config\nmodel_reasoning_effort = \"high\"\nlong_value = \"" + String(repeating: "long-value-", count: 32) + "\"\n"
    @State private var result = "Testing syntax…"
    @State private var language = "toml"
    @State private var running = false
    @State private var sends = 0
    var body: some View {
        VStack {
            Text(result)
            NativeSendButton(enabled: true, allowsModeSelection: running, onSend: { sends += 1 }, onChooseMode: {})
                .frame(width: 44, height: 44)
            NativeCodeView(text: $content, language: language, editable: true, wrapsLines: false,
                           identifier: "native.settings.advanced.editor")
        }.task { await run() }
    }
    @MainActor private func run() async {
        var checks: [String] = []
        do {
            let count = try await Task.detached { try NativeSyntaxSmoke.verify() }.value
            checks.append("\(count) language fixtures + filename detection + embedded JavaScript + queue/steer migration and idle send")
            let editor = try await findEditor()
            guard !editor.isLineWrappingEnabled, editor.showLineNumbers,
                  editor.contentSize.width > editor.bounds.width else {
                throw LinkError.message("Configuration editor wrapped long lines or lost horizontal scrolling")
            }
            let before = content
            editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
            editor.insertText("# edited\n")
            try await Task.sleep(nanoseconds: 100_000_000)
            guard content == before + "# edited\n" else { throw LinkError.message("Configuration editor did not update its draft") }
            checks.append("TOML editor + horizontal scrolling + line numbers + editable binding")
            language = "example.sql"
            content = "-- 中文😀\nSELECT 42 AS value;\n"
            let sql = try await findEditor()
            let offset = (sql.text as NSString).range(of: "42").location
            sql.selectedRange = NSRange(location: offset, length: 2)
            sql.insertText("'123'")
            try await Task.sleep(nanoseconds: 450_000_000)
            guard content == "-- 中文😀\nSELECT '123' AS value;\n",
                  sql.selectedRange == NSRange(location: offset + 5, length: 0), sql.undoManager?.canUndo == true else {
                throw LinkError.message("Lexical editor lost the draft, caret or undo after recoloring")
            }
            sql.undoManager?.undo()
            try await Task.sleep(nanoseconds: 450_000_000)
            guard content == "-- 中文😀\nSELECT 42 AS value;\n" else {
                throw LinkError.message("Lexical editor could not undo the edit")
            }
            checks.append("Native SQL editor Unicode edits, recoloring, caret and undo")
            for active in [false, true] {
                running = active
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let button = findSendButton(),
                      let hold = button.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first,
                      hold.isEnabled == active,
                      (button.accessibilityCustomActions?.isEmpty == false) == active else {
                    throw LinkError.message("Long press is not restricted to running tasks")
                }
                if !active {
                    button.sendActions(for: .touchUpInside)
                    guard sends == 1 else { throw LinkError.message("Idle send button did not send on tap") }
                }
            }
            checks.append("Idle tap sends directly; long press and accessibility mode selection enabled only during a running task")
            result = "PASS"
        } catch { result = "FAIL: " + error.localizedDescription }
        let report: [String: Any] = ["result": result, "checks": checks]
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("smoke.json"))
    }
    @MainActor private func findEditor() async throws -> Runestone.TextView {
        func find(_ view: UIView) -> Runestone.TextView? {
            if let text = view as? Runestone.TextView, text.accessibilityIdentifier == "native.settings.advanced.editor" { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        for _ in 0..<100 {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if let editor = windows.lazy.compactMap({ find($0) }).first, editor.isEditable,
               editor.text == content, editor.bounds.width > 0 { return editor }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LinkError.message("Configuration editor did not become ready")
    }
    @MainActor private func findSendButton() -> UIButton? {
        func find(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "native.send" { return button }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).lazy.compactMap { find($0) }.first
    }
}
#endif
