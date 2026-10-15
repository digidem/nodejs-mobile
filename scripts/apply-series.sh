#!/usr/bin/env bash
# Apply the patch series to an upstream clone, overlay the fork-only files and
# compare the result against expected-tree.txt. prepare.sh runs this on a
# fresh clone; run it yourself to resume after resolving a conflict, since
# prepare.sh refuses an existing out/.
#
# Usage:
#   scripts/apply-series.sh [--from <patch>] [out_dir]   # default out/
#
# Without --from, it resumes at the first patch in patches/series whose
# subject is not already in out_dir's history, and skips the overlay if
# that commit is already there.
#
# Env:
#   OLD_BASE        upstream tag being moved off; its blobs are fetched so
#                   --3way can merge files upstream changed since (default:
#                   the committed upstream-base.txt, when the working copy
#                   bumps it)
#   STRICT_VERIFY=1 exit non-zero on an expected-tree mismatch
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FROM=
if [ "${1:-}" = "--from" ]; then FROM=${2:?--from needs a patch name}; shift 2; fi
OUT=$(cd -- "${1:-"${HERE}/out"}" && pwd)
GIT_DIR_OUT=$(git -C "${OUT}" rev-parse --absolute-git-dir)

read_base() { grep -Ev '^\s*(#|$)' | head -n1 | tr -d '[:space:]'; }
BASE=$(read_base < "${HERE}/upstream-base.txt")

if [ -d "${GIT_DIR_OUT}/rebase-apply" ]; then
  echo "error: a 'git am' is in progress in ${OUT}; resolve it and run" >&2
  echo "  git -C ${OUT} am --continue    (or --skip)" >&2
  echo "then re-run this script to apply the rest." >&2
  exit 1
fi

if [ -z "${OLD_BASE:-}" ]; then
  OLD_BASE=$(git -C "${HERE}" show HEAD:upstream-base.txt 2>/dev/null | read_base || true)
fi
if [ -n "${OLD_BASE}" ] && [ "${OLD_BASE}" != "${BASE}" ] \
   && ! git -C "${OUT}" rev-parse -q --verify "refs/tags/${OLD_BASE}" >/dev/null; then
  echo "Fetching old base ${OLD_BASE} so --3way has the pre-image blobs..."
  git -C "${OUT}" fetch -q --depth 1 origin tag "${OLD_BASE}" \
    || echo "warning: could not fetch ${OLD_BASE}; patches on files upstream changed may fail with 'sha1 information is lacking'" >&2
fi

# Unfolds RFC 2822 continuation lines, as `git log %s` does.
patch_subject() {
  awk '/^Subject: /{sub(/^Subject: (\[PATCH[^]]*\] )?/, ""); s=$0; on=1; next}
       on && /^ /{s=s $0; next} on{print s; exit}' "$1"
}

conflict_summary() {
  local status md content
  status=$(git -C "${OUT}" status --porcelain)
  md=$(grep -cE '^(DU|UD) ' <<<"${status}" || true)
  content=$(grep -E '^(UU|AA|AU|UA|DD) ' <<<"${status}" | cut -c4- || true)
  [ "${md}" -gt 0 ] && echo "  ${md} modify/delete (upstream edited files this patch deletes) — intent is deletion:" \
    "git -C ${OUT} diff --name-only --diff-filter=U -z | git -C ${OUT} rm -q --pathspec-from-file=- --pathspec-file-nul"
  [ -n "${content}" ] && { echo "  content conflicts:"; sed 's/^/    /' <<<"${content}"; }
  [ "${md}" -eq 0 ] && [ -z "${content}" ] && echo "  no unmerged paths — see 'git -C ${OUT} am --show-current-patch=diff'"
  return 0
}

APPLIED=$(git -C "${OUT}" log --format=%s)
PATCHES=()
while IFS= read -r p || [ -n "${p}" ]; do
  [ -z "${p}" ] && continue
  case "${p}" in \#*) continue ;; esac
  PATCHES+=("${p}")
done < "${HERE}/patches/series"

start=0
if [ -n "${FROM}" ]; then
  while [ "${start}" -lt "${#PATCHES[@]}" ] && [ "${PATCHES[${start}]}" != "${FROM}" ]; do start=$((start + 1)); done
  [ "${start}" -lt "${#PATCHES[@]}" ] || { echo "error: ${FROM} is not in patches/series" >&2; exit 1; }
else
  while [ "${start}" -lt "${#PATCHES[@]}" ] \
        && grep -qxF -- "$(patch_subject "${HERE}/patches/${PATCHES[${start}]}")" <<<"${APPLIED}"; do
    start=$((start + 1))
  done
fi

echo "2/4 Applying $((${#PATCHES[@]} - start)) of ${#PATCHES[@]} patches..."
for p in "${PATCHES[@]:${start}}"; do
  # --3way: merge via embedded blob context when upstream drifted; real
  # conflicts still fail loudly. --whitespace=nowarn: byte-exact apply
  # regardless of the caller's apply.whitespace config.
  if ! git -C "${OUT}" am --3way --keep-cr --whitespace=nowarn "${HERE}/patches/${p}" > "${GIT_DIR_OUT}/apply-series.log" 2>&1; then
    if grep -q 'sha1 information is lacking' "${GIT_DIR_OUT}/apply-series.log"; then
      echo "error: patch failed: ${p} — no pre-image blobs; set OLD_BASE=<tag you are moving off> and re-run" >&2
      git -C "${OUT}" am --abort
    else
      echo "error: patch failed: ${p}" >&2
      conflict_summary >&2
      echo "Resolve in ${OUT}, 'git -C ${OUT} am --continue', then re-run scripts/apply-series.sh ${OUT}" >&2
    fi
    exit 1
  fi
done

LEFT=$(git -C "${OUT}" ls-files .github/workflows)
if [ -n "${LEFT}" ]; then
  echo "warning: upstream workflows the removal patch doesn't cover yet — 'git -C ${OUT} rm' them" >&2
  echo "and add each to patches/files.map against ci-remove-upstream-only-workflows-and-config.patch:" >&2
  sed 's/^/  /' <<<"${LEFT}" >&2
fi

OVERLAY_SUBJECT="mobile: fork-only files (mobile-src overlay)"
if grep -qxF -- "${OVERLAY_SUBJECT}" <<<"${APPLIED}"; then
  echo "3/4 Overlay already committed; skipping."
else
  echo "3/4 Overlaying mobile-src/ (fork-only files)..."
  # Enumerate via git, not the raw working dir: an untracked-and-ignored file
  # (.DS_Store, editor droppings) must not enter the product tree — it would
  # change the tree hash to one CI's clean checkout can never reproduce.
  # --cached picks up tracked files (working-tree content), --others
  # --exclude-standard picks up new not-yet-committed files from the
  # regenerate loop while honoring the gitignores.
  # Kept in the clone's git dir rather than mktemp, which sandboxed agents can't reach.
  MANIFEST="${GIT_DIR_OUT}/mobile-src-manifest"
  trap 'rm -f "${MANIFEST}"' EXIT
  ( cd "${HERE}/mobile-src" && git ls-files -z --cached --others --exclude-standard . ) > "${MANIFEST}"
  ( cd "${HERE}/mobile-src" && tar cf - --null -T "${MANIFEST}" ) | ( cd "${OUT}" && tar xf - )
  # Stage exactly what the overlay wrote, never `add -A`: a Finder-created
  # .DS_Store (or any other droppings in the clone) would otherwise be committed
  # into the product tree, whose hash CI's clean checkout can never reproduce.
  # -f because some tracked fork files (Xcode project internals) match the tree's
  # own .gitignore patterns; the overlay must land them all regardless.
  git -C "${OUT}" add -f --pathspec-from-file="${MANIFEST}" --pathspec-file-nul
  git -C "${OUT}" commit -q -m "${OVERLAY_SUBJECT}

Generated by scripts/prepare.sh from the recipe branch. Fork-only files
have no upstream counterpart; they are tracked as plain files in
mobile-src/, not as patches."
fi

echo "4/4 Verifying tree against expected-tree.txt..."
GOT=$(git -C "${OUT}" rev-parse 'HEAD^{tree}')
WANT=$(read_base < "${HERE}/expected-tree.txt")
if [ "${GOT}" = "${WANT}" ]; then
  echo "OK: reconstructed tree ${GOT} matches expected-tree.txt"
else
  echo "MISMATCH: reconstructed ${GOT} != expected ${WANT}" >&2
  echo "If the difference is intentional (you changed patches/ or mobile-src/)," >&2
  echo "update expected-tree.txt to ${GOT}." >&2
  [ "${STRICT_VERIFY:-0}" = "1" ] && exit 1
fi
