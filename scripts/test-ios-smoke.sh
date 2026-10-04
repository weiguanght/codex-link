#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
python3 "$ROOT/scripts/make-icon.py"
python3 "$ROOT/scripts/generate-project.py"
xcodebuild -project "$ROOT/ios/codex-link.xcodeproj" -target codex-link \
  -configuration Debug -sdk iphonesimulator ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=LINK_SMOKE \
  CONFIGURATION_BUILD_DIR="$ROOT/build/smoke-simulator" \
  SYMROOT="$ROOT/build/smoke-products" OBJROOT="$ROOT/build/smoke-intermediates" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_ENTITLEMENTS="$ROOT/ios/TrollStore.entitlements" \
  build > "$ROOT/build/smoke-build.log" 2>&1
# Let Xcode embed simulator entitlements in __TEXT,__entitlements. Manually
# signing the host Mach-O with iOS entitlements is not valid simulator signing.
STAGE="$(mktemp -d "$ROOT/build/smoke.XXXXXX")"
FIXTURE_PID=""
DEVICE=""
cleanup() {
  if [ -n "$DEVICE" ] && [ "${LINK_SMOKE_KEEP:-0}" != "1" ]; then
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
  fi
  if [ -n "$FIXTURE_PID" ]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
python3 "$ROOT/tests/smoke_fixture.py" "$STAGE/config.json" > "$ROOT/build/smoke-fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in {1..50}; do [ -f "$STAGE/config.json" ] && break; sleep .2; done
read -r PORT PIN ID < <(python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); print(x["port"],x["pin"],x["id"])' "$STAGE/config.json")
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(next(x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and "iOS" in x["name"]))')"
DEVICE="${LINK_SMOKE_DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl create "codex-link disposable smoke" com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation "$RUNTIME")"
fi
echo "Smoke simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl terminate "$DEVICE" local.codex.link >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$ROOT/build/smoke-simulator/CodexLink.app"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" local.codex.link data)"
rm -f "$CONTAINER/Documents/smoke.json"
SIMCTL_CHILD_LINK_SMOKE_PORT="$PORT" SIMCTL_CHILD_LINK_SMOKE_PIN="$PIN" SIMCTL_CHILD_LINK_SMOKE_ID="$ID" \
  xcrun simctl launch "$DEVICE" local.codex.link
for _ in {1..180}; do
  if [ -f "$CONTAINER/Documents/smoke.json" ]; then
    cp "$CONTAINER/Documents/smoke.json" "$ROOT/build/ios-smoke-result.json"
    cat "$ROOT/build/ios-smoke-result.json"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["result"]=="PASS" else 1)' "$ROOT/build/ios-smoke-result.json"
    exit
  fi
  sleep 1
done
echo 'Simulator smoke timed out' >&2
exit 1
