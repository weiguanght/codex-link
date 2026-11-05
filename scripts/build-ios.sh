#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ios/CodexLink/Info.plist")
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid CFBundleShortVersionString: $VERSION" >&2
  exit 1
fi
PACKAGE="codex-link-$VERSION"
python3 "$ROOT/scripts/make-icon.py"
python3 "$ROOT/scripts/generate-project.py"
mkdir -p "$ROOT/build"
xcodebuild -project "$ROOT/ios/codex-link.xcodeproj" -target codex-link \
  -configuration Release -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$ROOT/build/iphoneos" \
  SYMROOT="$ROOT/build/products" OBJROOT="$ROOT/build/intermediates" \
  CODE_SIGNING_ALLOWED=NO build
STAGE="$(mktemp -d "$ROOT/build/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$ROOT/build/iphoneos/CodexLink.app" "$STAGE/Payload/"
package_ipa() {
  local flavor="$1"
  local output="$ROOT/build/$PACKAGE-$flavor.ipa"
  local temporary="$ROOT/build/$PACKAGE-$flavor.ipa.tmp"
  rm -f "$temporary"
  (cd "$STAGE" && /usr/bin/zip -qr "$temporary" Payload)
  /usr/bin/unzip -tq "$temporary"
  mv -f "$temporary" "$output"
}
package_ipa unsigned
echo "未签名 IPA：$ROOT/build/$PACKAGE-unsigned.ipa"
echo "需使用你现有的 TrollStore 安装链路；安装和钥匙串行为仍需真机验证。"
# Ad-hoc signature with a dedicated, nonprivileged keychain group. This is a
# TrollStore-specific package, not an Apple provisioning profile or jailbreak.
/usr/bin/codesign --force --sign - --entitlements "$ROOT/ios/TrollStore.entitlements" \
  "$STAGE/Payload/CodexLink.app"
/usr/bin/codesign --verify --strict "$STAGE/Payload/CodexLink.app"
package_ipa TrollStore
echo "TrollStore 测试包：$ROOT/build/$PACKAGE-TrollStore.ipa"
python3 - "$ROOT/build" "$VERSION" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1]); version = sys.argv[2]
files = [root / ('codex-link-' + version + '-' + suffix + '.ipa') for suffix in ('TrollStore', 'unsigned')]
temporary = root / 'SHA256SUMS.txt.tmp'
temporary.write_text(''.join(
    hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in files))
temporary.replace(root / 'SHA256SUMS.txt')
PY
