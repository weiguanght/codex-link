#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/ios/Packages/iOS-LaTeX/Native/Cargo.toml"
target_dir="$root/build/ios-latex/rust"
lib_dir="${DERIVED_FILE_DIR:?Set by Xcode}"
cargo="$(command -v cargo || true)"
if [ -z "$cargo" ]; then
    cargo="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
fi
if [ ! -x "$cargo" ]; then
    echo "error: Install Rust with rustup to build iOS-LaTeX Light." >&2
    exit 1
fi

libs=()
for arch in ${ARCHS:?Set by Xcode}; do
    case "${PLATFORM_NAME:?Set by Xcode}/$arch" in
        iphoneos/arm64) target=aarch64-apple-ios ;;
        iphonesimulator/arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator/x86_64) target=x86_64-apple-ios ;;
        *) echo "error: iOS-LaTeX does not support $PLATFORM_NAME/$arch." >&2; exit 1 ;;
    esac
    CARGO_TARGET_DIR="$target_dir" "$cargo" build --manifest-path "$manifest" \
        --locked --release --no-default-features --target "$target" -p ios-latex
    libs+=("$target_dir/$target/release/libios_latex.a")
done

mkdir -p "$lib_dir"
xcrun lipo -create "${libs[@]}" -output "$lib_dir/libios_latex.a.new"
mv -f "$lib_dir/libios_latex.a.new" "$lib_dir/libios_latex.a"
