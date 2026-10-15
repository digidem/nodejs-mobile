#!/usr/bin/env bash
# Materialize the full nodejs-mobile source tree from this patches-only
# branch: clone upstream nodejs/node at the pinned base, apply the patch
# series, overlay the fork-only files, and verify the result byte-for-byte
# against expected-tree.txt.
#
# Usage:
#   scripts/prepare.sh [out_dir]        # default out/
#
# Env overrides (mainly for CI/offline use):
#   UPSTREAM_REPO   git URL or local path (default https://github.com/nodejs/node.git)
#   UPSTREAM_REF    tag/branch to clone   (default: first line of upstream-base.txt)
#   SKIP_VERIFY=1   don't fail on an expected-tree mismatch (prints both hashes)
#   OLD_BASE        tag being upgraded from; see scripts/apply-series.sh
#
# On a conflict, resolve in out_dir, `git -C out_dir am --continue`, then
# resume with scripts/apply-series.sh out_dir.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:-"${HERE}/out"}
UPSTREAM_REPO=${UPSTREAM_REPO:-https://github.com/nodejs/node.git}

BASE=$(grep -Ev '^\s*(#|$)' "${HERE}/upstream-base.txt" | head -n1 | tr -d '[:space:]')
UPSTREAM_REF=${UPSTREAM_REF:-${BASE}}
[ -n "${BASE}" ] || { echo "error: no base in upstream-base.txt" >&2; exit 1; }

if [ -e "${OUT}" ]; then
  echo "error: ${OUT} already exists — remove it (or pass another dir) and retry." >&2
  exit 1
fi

echo "1/4 Cloning ${UPSTREAM_REPO} @ ${UPSTREAM_REF} (shallow)..."
git clone --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_REPO}" "${OUT}"
git -C "${OUT}" config user.name  "${GIT_AUTHOR_NAME:-nodejs-mobile}"
git -C "${OUT}" config user.email "${GIT_AUTHOR_EMAIL:-nodejs-mobile@invalid}"

# Steps 2-4 live in apply-series.sh so a conflicted run can be resumed.
STRICT_VERIFY=$([ "${SKIP_VERIFY:-0}" = "1" ] && echo 0 || echo 1) \
  "${HERE}/scripts/apply-series.sh" "${OUT}"

echo "Done: ${OUT} is a full nodejs-mobile source tree (base ${BASE})."
echo "Build it as usual, e.g.: cd ${OUT} && ./tools/android_build.sh ..."
