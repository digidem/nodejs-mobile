#!/bin/bash
# Native-addon gate (Android emulator): stage the prebuilt crc-native addon + the
# test into the installed testnode app's private files dir, then run the test
# through the existing proxy (force-stop -> launch -> read per-launch verdict).
# native-lib.cpp sets NODE_MOBILE_ADDON to <filesDir>/crcnative.node, which the
# test dlopens. Proves the shipped libnode loads + runs a real N-API addon.
#
# Assumes the testnode app is already installed + primed (prepare-android-test.sh
# ran, so filesDir exists). Run inside the emulator-runner script block.
#
# Usage: run-android-addon.sh <crcnative.node>
set -uo pipefail

ADDON="$1"
PKG=nodejsmobile.test.testnode
FILES="/data/data/$PKG/files"
HERE="$(cd "$(dirname "$0")/crc-native" && pwd)"
# Use the proxy as installed by prepare-android-test.sh (out/android.release/node),
# NOT its source path: the proxy computes its test dir as `$(dirname $0)/../../test`,
# which only resolves from that installed location.
PROXY="$(cd "$(dirname "$0")/../../.." && pwd)/out/android.release/node"
[ "${DEVICE_ID:-}" = "" ] && TARGET="" || TARGET="-s $DEVICE_ID"
[ -x "$PROXY" ] || { echo "::error::proxy shim not found at $PROXY (run prepare-android-test.sh first)"; exit 1; }

# Push to a world-readable tmp dir, then run-as (the app uid) copies into the
# private files dir — adb can't write there directly.
adb $TARGET push "$ADDON" /data/local/tmp/crcnative.node
adb $TARGET push "$HERE/test-napi-addon.js" /data/local/tmp/test-napi-addon.js
adb $TARGET shell 'chmod 644 /data/local/tmp/crcnative.node /data/local/tmp/test-napi-addon.js'
adb $TARGET shell "run-as $PKG sh -c 'cp /data/local/tmp/crcnative.node files/crcnative.node && cp /data/local/tmp/test-napi-addon.js files/test-napi-addon.js'"
echo "staged addon + test into $FILES:"
adb $TARGET shell "run-as $PKG sh -c 'ls -l files/crcnative.node files/test-napi-addon.js'" || true

# Run via the proxy with the on-device absolute script path (no ./test/ or
# substitutedir substring, so MainActivity's rewriter leaves it untouched).
# The proxy's exit code is the verdict (0 = PASS).
"$PROXY" "$FILES/test-napi-addon.js"
rc=$?
[ "$rc" = 0 ] && echo "Android NAPI-addon: PASS" || echo "::error::Android NAPI-addon failed (rc=$rc)"
exit $rc
