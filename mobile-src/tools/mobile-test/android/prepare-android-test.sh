#!/bin/bash
set -e

# Use the environment variable to target a specific device
if [ "$DEVICE_ID" = "" ]; then
  echo "Target device: default"
  TARGET=""
else
  echo "Target device: $DEVICE_ID"
  TARGET="-s $DEVICE_ID"
fi

SCRIPT_BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
NODEJS_BASE_DIR="$( cd "$( dirname "$0" )" && cd .. && cd .. && cd .. && pwd )"
TEST_APP_BASE_DIR="$( cd "$( dirname "$0" )" && cd testnode/ && pwd )"
TEST_PROXY_TARGETDIR="$( cd "$NODEJS_BASE_DIR" && mkdir -p ./out/android.release/ && cd ./out/android.release/ && pwd )"

# Remove symbolic links, which make the Android asset package invalid.
set +e
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/input_link.txt"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/loop1"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/loop2"
unlink "$NODEJS_BASE_DIR/test/fixtures/wasi/subdir/outside.txt"
set -e

# Build the Android test app
( cd "$TEST_APP_BASE_DIR" && ./gradlew assembleDebug )

# Copy the Android proxy to the target directory.
cp "$SCRIPT_BASE_DIR/node-android-proxy.sh" "$TEST_PROXY_TARGETDIR/node"

# test.py loads every suite's config up front, and test/sea/testcfg.py resolves
# out/Release/node at config time (it predates cross-compiled layouts and raises
# if the host binary is absent). We don't build a host binary, so point it at the
# proxy to keep config from crashing; sea tests themselves are excluded from the
# mobile run (single-executable apps aren't supported on mobile).
mkdir -p "$NODEJS_BASE_DIR/out/Release"
ln -sf ../android.release/node "$NODEJS_BASE_DIR/out/Release/node"

# Kill the test app if it's running, then clear the log.
adb $TARGET shell 'am force-stop nodejsmobile.test.testnode'
adb $TARGET logcat -c

adb $TARGET install -r "$TEST_APP_BASE_DIR/app/build/outputs/apk/debug/app-debug.apk"

# Start the test app without parameters so it copies the bundled test assets to
# a writable location (the app reports COPYASSETS:PASS/FAIL when done).
adb $TARGET shell 'am start -n nodejsmobile.test.testnode/nodejsmobile.test.testnode.MainActivity' > /dev/null

# Poll the log buffer until COPYASSETS appears (see node-android-proxy.sh for why
# this replaced the old stream-and-kill wait). The copy can take a while on a
# large test suite, so allow a generous timeout.
TIMEOUT="${COPYASSETS_TIMEOUT:-180}"
RESULT=1
for _ in $(seq 1 "$TIMEOUT"); do
  line=$(adb $TARGET logcat -d -b main -v raw -s TestNode:V 2>/dev/null | grep -m1 '^COPYASSETS:' || true)
  if [ -n "$line" ]; then
    case "$line" in
      COPYASSETS:PASS*) RESULT=0 ;;
      *) RESULT=1 ;;
    esac
    break
  fi
  sleep 1
done

# Echo the raw stdout and stderr.
adb $TARGET shell 'logcat -d -b main -v raw -s TestNode:V -s nodejs'

[ "$RESULT" -eq 0 ] || exit 1
