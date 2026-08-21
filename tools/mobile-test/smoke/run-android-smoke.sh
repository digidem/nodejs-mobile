#!/bin/bash
# Push the embedder + libnode.so + libc++_shared.so + smoke.js to a connected
# Android device/emulator and assert the smoke marker and a clean exit.
# Boot smoke (docs/TESTING.md on the recipe branch).
#
# Usage: run-android-smoke.sh <embedder> <libnode.so> <libc++_shared.so> [serial]
set -euo pipefail

EMBEDDER="$1"; LIBNODE="$2"; LIBCXX="$3"; SERIAL="${4:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/data/local/tmp/nm-smoke
MARKER=NODEJS_MOBILE_SMOKE_OK

adbx() { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

adbx shell "rm -rf $DEST && mkdir -p $DEST"
adbx push "$LIBNODE" "$DEST/" >/dev/null
adbx push "$LIBCXX" "$DEST/" >/dev/null
adbx push "$EMBEDDER" "$DEST/node_smoke" >/dev/null
adbx push "$SCRIPT_DIR/smoke.js" "$DEST/" >/dev/null
adbx shell "chmod 755 $DEST/node_smoke"

OUT=$(adbx shell "cd $DEST && LD_LIBRARY_PATH=$DEST TMPDIR=$DEST ./node_smoke smoke.js; echo SMOKE_EXIT:\$?")
echo "----- device output -----"
echo "$OUT"
echo "--------------------------"

echo "$OUT" | grep -q "$MARKER"      || { echo "::error::Android smoke marker missing"; exit 1; }
echo "$OUT" | grep -q "SMOKE_EXIT:0" || { echo "::error::Android smoke exited non-zero"; exit 1; }
echo "Android smoke: PASS"
