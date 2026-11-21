# iOS-LaTeX Light

The Rust workspace, Swift display list decoder and CoreText renderer, KaTeX fonts, and licenses come from [iOS-LaTeX](https://github.com/weiguanght/iOS-LaTeX/tree/a6bc41fce094ad81553860be709d6a7f2e4ff602) at commit `a6bc41fce094ad81553860be709d6a7f2e4ff602`. The native layout core is based on RaTeX 0.1.16. The Xcode build uses Cargo.lock and disables default features to select Light.

Xcode builds the Light static library from source for the selected iOS architecture. The arm64e IPA build uses `rust-src` to compile the Rust standard library for `arm64e-apple-ios`. The build phase also supports arm64 and the simulator architectures. [Build script](../../../scripts/build-ios-latex.sh) · [License texts and font notices](iOSLaTeXNotices/)

The Swift renderer is compiled into the app target and loads the bundled `Fonts` folder. The app's Markdown adapter preserves the original TeX for selection and copying.
