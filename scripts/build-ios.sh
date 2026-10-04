#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
rm -f "$ROOT/build/codex-link-0.1.0-unsigned.ipa"
(cd "$STAGE" && /usr/bin/zip -qr "$ROOT/build/codex-link-0.1.0-unsigned.ipa" Payload)
echo "未签名 IPA：$ROOT/build/codex-link-0.1.0-unsigned.ipa"
echo "需使用你现有的 TrollStore 安装链路；安装和钥匙串行为仍需真机验证。"
# Ad-hoc signature with a dedicated, nonprivileged keychain group. This is a
# TrollStore-specific package, not an Apple provisioning profile or jailbreak.
/usr/bin/codesign --force --sign - --entitlements "$ROOT/ios/TrollStore.entitlements" \
  "$STAGE/Payload/CodexLink.app"
/usr/bin/codesign --verify --strict "$STAGE/Payload/CodexLink.app"
rm -f "$ROOT/build/codex-link-0.1.0-TrollStore.ipa"
(cd "$STAGE" && /usr/bin/zip -qr "$ROOT/build/codex-link-0.1.0-TrollStore.ipa" Payload)
echo "TrollStore 测试包：$ROOT/build/codex-link-0.1.0-TrollStore.ipa"
python3 - "$ROOT/build" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
files = [root / ('codex-link-0.1.0-' + suffix + '.ipa') for suffix in ('TrollStore', 'unsigned')]
(root / 'SHA256SUMS.txt').write_text(''.join(
    hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in files))
PY
