#!/bin/bash
# Build, sign, install and prime the testnode app on a *physical* iOS device.
# Everything device-facing goes through `xcrun devicectl` (CoreDevice, Xcode
# 15+): ios-deploy's launch phase is dead on iOS 17+ (see node-ios-proxy.sh),
# and devicectl covers install and launch-with-arguments, so ios-deploy is no
# longer needed at all.
#
# Env knobs:
#   DEVICE_ID           CoreDevice identifier or name (xcrun devicectl list
#                       devices). Auto-selected when exactly one device is
#                       connected.
#   NODE_IOS_DEV_TEAM   Apple Development team id. When set, xcodebuild signs
#                       with it (automatic signing + -allowProvisioningUpdates,
#                       which needs the account signed into Xcode). Without it
#                       the project's own signing settings apply — a bare
#                       checkout has none, so a device build normally needs
#                       this.
#   NODE_IOS_BUNDLE_ID  Override the app bundle id (default nodejsmobile.test)
#                       if that id is taken on your account. The proxy reads
#                       the same variable.
set -euo pipefail

SCRIPT_BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
NODEJS_BASE_DIR="$( cd "$( dirname "$0" )" && cd .. && cd .. && cd .. && pwd )"
TEST_PROXY_TARGETDIR="$( cd "$NODEJS_BASE_DIR" && mkdir -p ./out/ios.release/ && cd ./out/ios.release/ && pwd )"

BUNDLE_ID="${NODE_IOS_BUNDLE_ID:-nodejsmobile.test}"

# Same device resolution as node-ios-proxy.sh: CoreDevice identifier, not the
# classic UDID; auto-select only an unambiguous single connected device.
DEVICE_ID="${DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVJSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true
  DEVICE_ID="$(python3 - "$DEVJSON" <<'PYEOF'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
connected = [d["identifier"] for d in devs
             if d.get("connectionProperties", {}).get("tunnelState") == "connected"]
if len(connected) == 1:
    print(connected[0])
PYEOF
)"
  rm -f "$DEVJSON"
  [ -n "$DEVICE_ID" ] || { echo "error: no single connected device — set DEVICE_ID to a CoreDevice identifier (xcrun devicectl list devices)" >&2; exit 1; }
fi

# Remove symbolic links, which might make the iOS application invalid to install
set +e
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/input_link.txt"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/loop1"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/loop2"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/outside.txt"
set -e

SIGN_ARGS=()
if [ -n "${NODE_IOS_DEV_TEAM:-}" ]; then
  SIGN_ARGS=(DEVELOPMENT_TEAM="$NODE_IOS_DEV_TEAM"
             CODE_SIGN_IDENTITY="Apple Development"
             -allowProvisioningUpdates)
fi
BUNDLE_ARGS=()
if [ "$BUNDLE_ID" != "nodejsmobile.test" ]; then
  BUNDLE_ARGS=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
fi

# ${arr[@]+…}: macOS's bash 3.2 treats an empty array as unbound under set -u.
xcodebuild build -project "$SCRIPT_BASE_DIR/testnode/testnode.xcodeproj" \
  -target "testnode" -configuration Release -arch arm64 -sdk "iphoneos" \
  SYMROOT="$TEST_PROXY_TARGETDIR" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"}

cp "$SCRIPT_BASE_DIR/node-ios-proxy.sh" "$TEST_PROXY_TARGETDIR/node"

xcrun devicectl device install app --device "$DEVICE_ID" \
  "$TEST_PROXY_TARGETDIR/Release-iphoneos/testnode.app"

# Prime the on-device test assets: one launch in --copy-path-for-testing mode
# copies the bundled test/ tree into Documents and exits. --console blocks
# until that copy has finished, so the first real test can't race it.
xcrun devicectl device process launch --device "$DEVICE_ID" --console \
  --terminate-existing "$BUNDLE_ID" --copy-path-for-testing
