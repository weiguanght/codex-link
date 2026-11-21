# iOS-LaTeX Light

The Rust workspace, Swift display list decoder and CoreText renderer, KaTeX fonts, and licenses come from [iOS-LaTeX](https://github.com/weiguanght/iOS-LaTeX/tree/a6bc41fce094ad81553860be709d6a7f2e4ff602) at commit `a6bc41fce094ad81553860be709d6a7f2e4ff602`. The native layout core is based on RaTeX 0.1.16. The Xcode build uses Cargo.lock and disables default features to select Light.

The supplied Light archive targets arm64e. The same source builds for iOS arm64 and the supported simulator architectures. Xcode builds and links the static library via [the build script](../../../scripts/build-ios-latex.sh). [License texts and font notices](iOSLaTeXNotices/) accompany the app resources.

The Swift renderer is compiled into the app target and loads the bundled `Fonts` folder. The app's Markdown adapter preserves the original TeX for selection and copying.
