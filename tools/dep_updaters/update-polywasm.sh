#!/bin/sh

# Update — or verify — the vendored polywasm in deps/polywasm.
#
# Mobile-only dependency: a pure-JS WebAssembly implementation that
# lib/internal/process/pre_execution.js installs as globalThis.WebAssembly when
# the engine ships none, which is the case on iOS (jitless V8). See
# deps/polywasm/README.md for the provenance and why it is vendored.
#
# Usage:
#   tools/dep_updaters/update-polywasm.sh            # verify the vendored copy
#   tools/dep_updaters/update-polywasm.sh 0.3.0      # vendor that version
#
# With no argument this is a checker, not an updater: it re-downloads the
# version recorded in deps/polywasm/README.md, asserts both recorded sha256s,
# regenerates the file from the tarball and fails unless the result is
# byte-identical to what is in the tree. That gives a reviewer the provenance
# guarantee of a download-at-build-time dependency without making any build
# step depend on the npm registry.
#
# Deliberately not run by CI, for that same reason.

set -e

BASE_DIR=$(cd "$(dirname "$0")/../.." && pwd)
DEP_DIR="$BASE_DIR/deps/polywasm"
VENDORED="$DEP_DIR/polywasm.js"
README="$DEP_DIR/README.md"

# Recorded version + hashes live in the README table, so there is one source of
# truth a human reads and no second file to forget to update.
RECORDED_VERSION=$(sed -n 's/.*`polywasm`](https:\/\/www.npmjs.com\/package\/polywasm) `\([0-9][^`]*\)`.*/\1/p' "$README" | head -n1)
RECORDED_TGZ_SHA=$(sed -n 's/^| Tarball `sha256` | `\([0-9a-f]\{64\}\)` |$/\1/p' "$README" | head -n1)
RECORDED_JS_SHA=$(sed -n 's/^| `package\/index.js` `sha256` | `\([0-9a-f]\{64\}\)` |$/\1/p' "$README" | head -n1)
[ -n "$RECORDED_VERSION" ] || { echo "error: no version found in $README" >&2; exit 1; }

VERSION="${1:-$RECORDED_VERSION}"
if [ "$VERSION" = "$RECORDED_VERSION" ]; then
  MODE=verify
else
  MODE=update
  RECORDED_TGZ_SHA=
  RECORDED_JS_SHA=
fi
echo "polywasm $VERSION (mode: $MODE)"

WORKSPACE=$(mktemp -d 2> /dev/null || mktemp -d -t 'tmp')
cleanup () {
  EXIT_CODE=$?
  [ -d "$WORKSPACE" ] && rm -rf "$WORKSPACE"
  exit $EXIT_CODE
}
trap cleanup INT TERM EXIT

TGZ="$WORKSPACE/polywasm-$VERSION.tgz"
curl -sSfL -o "$TGZ" "https://registry.npmjs.org/polywasm/-/polywasm-$VERSION.tgz"
tar -xzf "$TGZ" -C "$WORKSPACE" package/index.js package/LICENSE.md

sha256 () {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1   # macOS
  fi
}
TGZ_SHA=$(sha256 "$TGZ")
JS_SHA=$(sha256 "$WORKSPACE/package/index.js")
echo "  tarball  sha256 $TGZ_SHA"
echo "  index.js sha256 $JS_SHA"

check_sha () { # name got want
  [ -z "$3" ] && return 0
  [ "$2" = "$3" ] && return 0
  echo "error: $1 sha256 mismatch — the registry served different bytes than recorded" >&2
  echo "  got  $2" >&2
  echo "  want $3" >&2
  exit 1
}
check_sha tarball "$TGZ_SHA" "$RECORDED_TGZ_SHA"
check_sha index.js "$JS_SHA" "$RECORDED_JS_SHA"

# The single edit the vendored copy carries: js2c wraps builtins as CommonJS, so
# the ESM export has to go. Assert the exact shape rather than pattern-matching,
# so a reshaped upstream bundle stops the update instead of being mangled.
# python3 (not sed/head -n -3) because it is already a build prerequisite and
# behaves the same on macOS and Linux.
python3 - "$WORKSPACE/package/index.js" "$WORKSPACE/polywasm.js" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
esm = 'export {\n  wasmAPI as WebAssembly\n};\n'
if not s.endswith(esm):
    sys.exit('error: upstream export shape changed; expected the bundle to end '
             'with:\n' + esm + '\ngot:\n' + s[-120:])
nonascii = [i for i, c in enumerate(s) if ord(c) > 127]
if nonascii:
    sys.exit(f'error: upstream bundle is no longer ASCII (first at offset '
             f'{nonascii[0]}); js2c would embed it as UTF-16, doubling its size '
             'in every binary. Decide deliberately before vendoring this.')
open(dst, 'w', encoding='utf-8').write(
    s[:-len(esm)] + 'module.exports = { WebAssembly: wasmAPI };\n')
PY

if [ "$MODE" = verify ]; then
  if cmp -s "$WORKSPACE/polywasm.js" "$VENDORED"; then
    echo "OK: deps/polywasm/polywasm.js reproduces polywasm@$VERSION from npm"
  else
    echo "error: the vendored copy does NOT match polywasm@$VERSION from npm:" >&2
    diff "$WORKSPACE/polywasm.js" "$VENDORED" | head -n 40 >&2
    exit 1
  fi
  if ! cmp -s "$WORKSPACE/package/LICENSE.md" "$DEP_DIR/LICENSE.md"; then
    echo "warning: deps/polywasm/LICENSE.md differs from the published tarball" >&2
  fi
  exit 0
fi

cp "$WORKSPACE/polywasm.js" "$VENDORED"
cp "$WORKSPACE/package/LICENSE.md" "$DEP_DIR/LICENSE.md"
cat <<EOF

Vendored polywasm $VERSION into deps/polywasm/. Still to do by hand:
  1. update the version + both hashes in deps/polywasm/README.md
  2. check the tree's root LICENSE if upstream's copyright line changed
  3. scripts/regenerate-patches.py out, and commit the printed expected-tree hash
EOF
