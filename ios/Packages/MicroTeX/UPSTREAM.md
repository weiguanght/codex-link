# MicroTeX Sources

The C++ engine and rendering data are vendored from [NanoMichael/MicroTeX](https://github.com/NanoMichael/MicroTeX) at commit `0e3707f6dafebb121d98b53c64364d16fefe481d`. The upstream repository is MIT licensed; its license and bundled font notices remain alongside the source and resources.

The pinned upstream source exposes the `tex::LaTeX` API. This app compiles that source directly and supplies its own CoreText/CoreGraphics backend in `src/platform/apple/graphic_apple.mm`. It does not link or embed DeepSeek's `DSLatex.framework`.

The engine's XML resource parser uses [TinyXML2](https://github.com/leethomason/tinyxml2), vendored at commit `321ea883b7190d4e85cae5512a12e5eaa8f8731f` under `third_party/tinyxml2/`, with its MIT license.
