# 语法高亮

配置编辑器、文件预览、回复代码块与差异中的代码共用 `NativeCodeLanguages`，按文件名、扩展名或代码围栏的语言名识别语法。初次高亮在后台计算。HTML 内嵌 JavaScript／CSS 和 Markdown 源码中的内嵌语法由 Tree-sitter 解析。

高级配置页采用 TOML 语法，固定不自动换行，支持横向滚动、行号和搜索。编辑和重新读取继续使用原来的草稿、版本校验与原子保存流程。

## 语言目录

共支持 60 种高亮模式，包括 47 个 Tree-sitter 模块、独立的 JSX 查询，以及 12 种轻量高亮模式。

| 类别 | 支持语法 |
| --- | --- |
| 系统与应用 | C、C++、Objective-C、C#、Swift、Rust、Go、Java、Kotlin、Dart、Zig |
| Web | HTML、XML、CSS、SCSS、JavaScript、JSX、TypeScript、TSX、Astro、Svelte、Glimmer、PHP |
| 脚本与计算 | Bash、Fish、Python、Ruby、Perl、Lua、Julia、R |
| 配置与数据 | JSON、JSON5、YAML、TOML、SQL、PostgreSQL、Dockerfile、CMake、GoMod、HCL、Bicep、Proto、Nix |
| 其他 | Agda、Elixir、Elm、Haskell、OCaml、OCamlInterface、Pascal、Scala、Verilog／SystemVerilog、LaTeX、Markdown、MarkdownInline、Diff、Regex、JSDoc、Comment |

常用别名包括 `c++`／`cpp`、`c#`／`cs`、`objc`、`terraform`／`tf`、`protobuf`、`golang`、`shell`、`jsonc`。`jsonc` 使用 JSON5 语法着色，保存校验仍由目标格式负责。`.m`／`.mm` 按 Objective-C 识别。

特殊文件名识别包括 `Dockerfile`／`Dockerfile.dev`／`Containerfile`、`CMakeLists.txt`、`go.mod`、`.env`／`.env.local`、`.bashrc`／`.zshrc`、`Gemfile`／`Podfile`／`Rakefile`。XML 规则也用于文本格式的 plist、storyboard、xib 和 entitlements。未知类型使用纯文本。

## 高亮引擎

- Verilog／SystemVerilog、LaTeX、SQL、PostgreSQL、Perl、Scala、OCaml（含 `.mli`）、Julia、Haskell 和 Elixir 使用 Highlight.js 11.12.0。Agda 使用 Prism 1.30.0。未指定方言的 `.sql` 文件使用通用 SQL，代码围栏可用 `pgsql`／`postgresql` 指定方言。
- 这些模式在系统 JavaScriptCore 中离线分词，由 Runestone 原生绘制。文件编辑后后台重新着色，行号、搜索和换行继续由编辑器处理。语法折叠和树驱动缩进适用于 Tree-sitter 模式，Markdown 源码编辑器也只为这些模式提供内嵌高亮。渲染后的 Markdown 代码块支持两种引擎。
- 单段轻量着色上限为 256 Ki 个 UTF-16 码元，超过时显示纯文本。

## 来源与验证

解析器、查询和 JavaScript 资源随包提供，常规构建可离线执行。`ios/Packages/Runestone/SOURCES.json` 和 `LanguageSources/` 保留 Tree-sitter 导入的来源记录，Tree-sitter 运行时固定为 0.25.3。轻量高亮资源可从指定版本的 npm 归档重新生成，生成脚本校验归档 SHA-256。

```sh
python3 scripts/bundle-syntax.py /path/to/highlight.js-11.12.0.tgz /path/to/prismjs-1.30.0.tgz
LINK_SYNTAX_ONLY=1 bash scripts/test-ios-smoke.sh
```

定向 iOS 模拟器验证覆盖 60 种语法、扩展名和特殊文件名识别、HTML 内嵌 JavaScript、SQL 编辑后的光标与撤销，以及 TOML 编辑器的横向滚动、行号和编辑绑定。新版高亮通过覆盖安装 IPA 生效。
