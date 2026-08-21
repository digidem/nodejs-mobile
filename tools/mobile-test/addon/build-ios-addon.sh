#!/bin/bash
# Build the crc-native N-API addon for one iOS slice, linked against a prebuilt
# NodeMobile.xcframework. NodeMobile is a *dynamic* framework that re-exports
# the napi_* symbols (it -all_loads libnode.a), so we link -framework NodeMobile
# and the napi_* references get a two-level binding to it — NOT a bare
# `-undefined dynamic_lookup` flat search, which is the fragile path.
#
# Usage: build-ios-addon.sh <xcframework-dir> <slice> <include-dir> <out.node>
#   <slice>       e.g. ios-arm64-simulator | ios-arm64
#   <include-dir> dir containing node_api.h (artifact include/node, or src/)
set -euo pipefail

XCF="$1"; SLICE="$2"; INC="$3"; OUT="$4"
HERE="$(cd "$(dirname "$0")/crc-native" && pwd)"

case "$SLICE" in
  *simulator) SDK=iphonesimulator ;;
  *)          SDK=iphoneos ;;
esac

xcrun -sdk "$SDK" clang -arch arm64 -dynamiclib -fPIC \
  -DNODE_GYP_MODULE_NAME=crc_native \
  -I "$HERE" -I "$INC" \
  "$HERE/binding.c" "$HERE/crc32.c" \
  -F "$XCF/$SLICE" -framework NodeMobile \
  -Wl,-rpath,@executable_path/Frameworks \
  -o "$OUT"

echo "built $OUT"
# Sanity: napi_* must be undefined-but-bound to NodeMobile (two-level namespace).
echo "--- napi_* bindings (expect '(undefined) ... from NodeMobile') ---"
xcrun nm -mu "$OUT" | grep -i napi || echo "::warning::no napi_* symbols referenced"
