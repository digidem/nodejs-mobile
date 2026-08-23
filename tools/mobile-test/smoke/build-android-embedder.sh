#!/bin/bash
# Compile the minimal Node embedder (node_embedder.cpp) for one Android ABI,
# linking the prebuilt libnode.so. Boot smoke (docs/TESTING.md on the
# recipe branch).
#
# Usage: build-android-embedder.sh <ndk_path> <abi> <libnode_dir> <out_path>
#   abi:         x86_64 | arm64-v8a | armeabi-v7a
#   libnode_dir: directory containing libnode.so for that abi
set -euo pipefail

NDK="$1"; ABI="$2"; LIBNODE_DIR="$3"; OUT="$4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# API 24 matches ANDROID_TARGET_SDK_VERSION used to build libnode.so.
"$BIN/${TRIPLE}24-clang++" \
  "$SCRIPT_DIR/node_embedder.cpp" \
  -o "$OUT" \
  -L "$LIBNODE_DIR" -lnode \
  -Wl,-z,max-page-size=16384

echo "Built embedder: $OUT"
