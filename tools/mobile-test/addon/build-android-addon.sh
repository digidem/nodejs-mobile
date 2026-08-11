#!/bin/bash
# Compile the crc-native N-API addon as a shared library for one Android ABI,
# linking the prebuilt libnode.so (which exports napi_*). Built from source
# against the candidate build's headers so the addon binds to THIS libnode, and
# with the same 16 KB max-page-size as libnode.so so it loads on 16 KB-page
# hardware (see ANDROID_LDFLAGS in build.yml on the recipe branch).
#
# Usage: build-android-addon.sh <ndk_path> <abi> <libnode_dir> <include_dir> <out.node>
#   abi:         x86_64 | arm64-v8a | armeabi-v7a
#   libnode_dir: directory containing libnode.so for that abi
#   include_dir: directory containing node_api.h (artifact include/node, or src/)
set -euo pipefail

NDK="$1"; ABI="$2"; LIBNODE_DIR="$3"; INC="$4"; OUT="$5"
HERE="$(cd "$(dirname "$0")/crc-native" && pwd)"

case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;
  Linux)  HOST_TAG=linux-x86_64 ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"

case "$ABI" in
  x86_64)      TRIPLE=x86_64-linux-android ;;
  arm64-v8a)   TRIPLE=aarch64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
  *) echo "unknown abi: $ABI" >&2; exit 1 ;;
esac

# API 24 matches ANDROID_TARGET_SDK_VERSION used to build libnode.so. C, not C++.
"$BIN/${TRIPLE}24-clang" \
  -shared -fPIC \
  -DNODE_GYP_MODULE_NAME=crc_native \
  -I "$HERE" -I "$INC" \
  "$HERE/binding.c" "$HERE/crc32.c" \
  -o "$OUT" \
  -L "$LIBNODE_DIR" -lnode \
  -Wl,-z,max-page-size=16384

echo "Built addon: $OUT"
# Sanity: addon exports the N-API registration entry + imports napi_* from libnode.
"$BIN/llvm-nm" -D "$OUT" 2>/dev/null | grep -iE "napi_register_module_v1|crc_u32_napi" | head || true
