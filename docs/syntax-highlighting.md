# 语法高亮

配置编辑器、文件预览、回复代码块与差异中的代码共用 `NativeCodeLanguages`，按文件名、扩展名或代码围栏的语言名识别语法。每个编辑器持有独立语言与解析状态；后台执行初始解析。HTML 的 JavaScript／CSS、Markdown 代码围栏等嵌入语法通过同一目录按需提供。

高级配置页采用 TOML 语法，固定不自动换行，支持横向滚动、行号和搜索。编辑和重新读取继续使用原来的草稿、版本校验与原子保存流程。

## 语言目录

参考用户提供的 TreeSitterLanguages 源码，新增 43 个模块，合计 58 个模块，JSX 使用 JavaScript 包提供的独立查询规则。

| 类别 | 支持语法 |
| --- | --- |
| 系统与应用 | C、C++、Objective-C、C#、Swift、Rust、Go、Java、Kotlin、Dart、Zig |
| Web | HTML、XML、CSS、SCSS、JavaScript、JSX、TypeScript、TSX、Astro、Svelte、Glimmer、PHP |
| 脚本与计算 | Bash、Fish、Python、Ruby、Perl、Lua、Julia、R |
| 配置与数据 | JSON、JSON5、YAML、TOML、SQL、Dockerfile、CMake、GoMod、HCL、Bicep、Proto、Nix |
| 其他 | Agda、Elixir、Elm、Haskell、OCaml、OCamlInterface、Pascal、Scala、Verilog、LaTeX、Markdown、MarkdownInline、Diff、Regex、JSDoc、Comment |

常用别名包括 `c++`／`cpp`、`c#`／`cs`、`objc`、`terraform`／`tf`、`protobuf`、`golang`、`shell`、`jsonc`。`jsonc` 使用 JSON5 语法着色，保存校验仍由目标格式负责。`.m`／`.mm` 按 Objective-C 识别。

特殊文件名识别包括 `Dockerfile`／`Dockerfile.dev`／`Containerfile`、`CMakeLists.txt`、`go.mod`、`.env`／`.env.local`、`.bashrc`／`.zshrc`、`Gemfile`／`Podfile`／`Rakefile`。XML 规则也用于文本格式的 plist、storyboard、xib 和 entitlements。未知类型使用纯文本。

## 来源与验证

所有解析器、扫描器、查询和 Runestone 包装随项目提供，构建时不联网下载。`ios/Packages/Runestone/SOURCES.json` 记录输入源码的 SHA-256；`LanguageSources/` 保留各语言上游版本、查询来源与测试示例，`LanguageLicenses/TreeSitterLanguages/` 保留对应许可。Tree-sitter 运行时继续使用本项目固定的 0.25.3，支持语法 ABI 13–15。

`NativeSyntaxSmoke` 在模拟器中以实际 Runestone 高亮器运行 59 组语言示例，验证文本完整、代表性 token 着色、完整目录覆盖、扩展名与特殊文件名识别，以及 HTML 内嵌 JavaScript 着色。

定向模拟器验证：

```sh
LINK_SYNTAX_ONLY=1 bash scripts/test-ios-smoke.sh
```

此模式运行全部语言示例、后续发送方式迁移和配置编辑器的横向滚动、行号及编辑绑定检查。

本次定向模拟器验证通过：59 组语言示例、HTML 嵌入 JavaScript、配置编辑器不换行与横向滚动、编辑绑定，以及空闲单击／执行中长按行为。
