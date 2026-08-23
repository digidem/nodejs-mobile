#!/bin/bash
# Build the testnode app for the iOS simulator (arm64) against the prebuilt
# out_ios/NodeMobile.xcframework. Boot smoke (docs/TESTING.md on the
# recipe branch).
#
# The xcframework must already be at <repo>/out_ios/NodeMobile.xcframework
# (the testnode project references it by relative path).
#
# Usage: build-ios-testnode.sh [symroot]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/../ios/testnode/testnode.xcodeproj"
SYMROOT="${1:-$PWD/out_testnode}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The testnode project bundles the whole upstream test/ dir as a resource, and
# test/fixtures/wasi/subdir/ holds relative/dangling symlinks that make the
# simulator .app invalid to install (xcrun simctl install rejects it). Strip
# them before building, same as tools/mobile-test/ios/prepare-ios-tests.sh.
# CI-only side effect on an ephemeral checkout.
rm -f "$REPO_ROOT"/test/fixtures/wasi/subdir/input_link.txt \
      "$REPO_ROOT"/test/fixtures/wasi/subdir/loop1 \
      "$REPO_ROOT"/test/fixtures/wasi/subdir/loop2 \
      "$REPO_ROOT"/test/fixtures/wasi/subdir/outside.txt

xcodebuild build \
  -project "$PROJECT" \
  -target testnode \
  -configuration Release \
  -sdk iphonesimulator \
  -arch arm64 \
  SYMROOT="$SYMROOT" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

echo "App: $SYMROOT/Release-iphonesimulator/testnode.app"
