#!/bin/bash
set -euo pipefail

# Build the testnode app for the iOS *simulator*, install it on $DEVICE_ID, and
# copy the bundled test assets into the app's Documents dir.
# Simulator harness for the device test suites (docs/TESTING.md on the recipe branch).
#
# This is the simulator counterpart of prepare-ios-tests.sh, which targets a
# physical device via devicectl.

SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../../.." && pwd )"
BUNDLE=nodejsmobile.test
: "${DEVICE_ID:?set DEVICE_ID to the target simulator UDID (xcrun simctl list devices)}"
UDID="$DEVICE_ID"
SYMROOT="${SYMROOT:-$REPO_ROOT/out_ios_testnode}"

# Build the app for the simulator (bundles the test/ folder as a resource).
"$SCRIPT_DIR/../smoke/build-ios-testnode.sh" "$SYMROOT"
APP="$SYMROOT/Release-iphonesimulator/testnode.app"

xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"

# Launch once with --copy-path-for-testing so the app copies its bundled test/
# folder into Documents (a real, host-shared dir on the simulator). The app
# exits (main.m returns 0) once the copy finishes, so wait for the PROCESS to
# exit rather than for $DOCS/test to merely exist: that dir is created at the
# START of the copy, so breaking on its existence killed the app mid-copy and
# left a partial tree (~1600 of ~4000 files) -> MODULE_NOT_FOUND at run time.
DOCS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents"
rm -rf "$DOCS/test"
xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE" --copy-path-for-testing >/dev/null 2>&1 &
LP=$!
for _ in $(seq 1 600); do
  kill -0 "$LP" 2>/dev/null || break
  sleep 1
done
kill "$LP" 2>/dev/null || true
wait "$LP" 2>/dev/null || true
[ -d "$DOCS/test/parallel" ] && [ -n "$(ls -A "$DOCS/test/parallel" 2>/dev/null)" ] \
  || { echo "::error::test assets were not fully copied to $DOCS"; exit 1; }

echo "Prepared iOS simulator tests in: $DOCS"
