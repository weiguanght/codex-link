; Adapted for Runestone; source and license notices: LANGUAGE_SOURCES.md and Tests/Additional/Zig.json.
; Variables

(identifier) @variable

; Parameters

(parameter
  name: (identifier) @parameter)

; Types

(parameter
  type: (identifier) @type)

((identifier) @type
  (#match? @type "^[A-Z_][a-zA-Z0-9_]*"))

(variable_declaration
  (identifier) @type
  "="
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ])

[
  (builtin_type)
  "anyframe"
] @type.builtin

; Constants

((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_0-9]+$"))

[
  "null"
  "unreachable"
  "undefined"
] @constant.builtin

(field_expression
  .
  member: (identifier) @constant)

(enum_declaration
  (container_field
    type: (identifier) @constant))

; Labels

(block_label (identifier) @label)

(break_label (identifier) @label)

; Fields

(field_initializer
  .
  (identifier) @property)

(field_expression
  (_)
  member: (identifier) @property)

(container_field
  name: (identifier) @property)

(initializer_list
  (assignment_expression
      left: (field_expression
              .
              member: (identifier) @property)))

; Functions

(builtin_identifier) @function.builtin

(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (field_expression
    member: (identifier) @function.call))

(function_declaration
  name: (identifier) @function)

; Modules

(variable_declaration
  (identifier) @namespace
  (builtin_function
    (builtin_identifier) @keyword
    (#match? @keyword "^(@import|@cImport)$")))

; Builtins

[
  "c"
  "..."
] @variable.builtin

((identifier) @variable.builtin
  (#eq? @variable.builtin "_"))

(calling_convention
  (identifier) @variable.builtin)

; Keywords

[
  "asm"
  "defer"
  "errdefer"
  "test"
  "error"
  "const"
  "var"
] @keyword

[
  "struct"
  "union"
  "enum"
  "opaque"
] @keyword

[
  "async"
  "await"
  "suspend"
  "nosuspend"
  "resume"
] @keyword

"fn" @keyword

[
  "and"
  "or"
  "orelse"
] @keyword

"return" @keyword

[
  "if"
  "else"
  "switch"
] @keyword

[
  "for"
  "while"
  "break"
  "continue"
] @keyword

[
  "usingnamespace"
  "export"
] @keyword

[
  "try"
  "catch"
] @keyword

[
  "volatile"
  "allowzero"
  "noalias"
  "addrspace"
  "align"
  "callconv"
  "linksection"
  "pub"
  "inline"
  "noinline"
  "extern"
  "comptime"
  "packed"
  "threadlocal"
] @keyword

; Operator

[
  "="
  "*="
  "*%="
  "*|="
  "/="
  "%="
  "+="
  "+%="
  "+|="
  "-="
  "-%="
  "-|="
  "<<="
  "<<|="
  ">>="
  "&="
  "^="
  "|="
  "!"
  "~"
  "-"
  "-%"
  "&"
  "=="
  "!="
  ">"
  ">="
  "<="
  "<"
  "&"
  "^"
  "|"
  "<<"
  ">>"
  "<<|"
  "+"
  "++"
  "+%"
  "-%"
  "+|"
  "-|"
  "*"
  "/"
  "%"
  "**"
  "*%"
  "*|"
  "||"
  ".*"
  ".?"
  "?"
  ".."
] @operator

; Literals

(character) @string

([
  (string)
  (multiline_string)
] @string)

(integer) @number

(float) @number

(boolean) @boolean

(escape_sequence) @string.escape

; Punctuation

[
  "["
  "]"
  "("
  ")"
  "{"
  "}"
] @punctuation.bracket

[
  ";"
  "."
  ","
  ":"
  "=>"
  "->"
] @punctuation.delimiter

(payload "|" @punctuation.bracket)

; Comments

(comment) @comment 

((comment) @comment.documentation
  (#match? @comment.documentation "^//!"))
