# Updating nodejs-mobile to a newer upstream Node.js

Bumping to a newer upstream Node.js release means re-basing the patch
series onto the new tag. There is no branch rebasing and no force-pushing —
the patches are files, and the upgrade is an ordinary reviewable PR.

Expect a handful of small conflicts resolvable in minutes — plus,
occasionally, one that only the compile catches (see the warning below).

## Re-base the series

```sh
$EDITOR upstream-base.txt                 # bump the tag, e.g. v24.19.0
scripts/prepare.sh                        # clone new base + apply series
```

`prepare.sh` stops at the first patch that no longer applies. For each
conflict, resolve **in `out/`** with the usual `git am` loop
(`git status` → edit → `git add` → `git am --continue`), guided by one
question: *what does this patch intend, and what did upstream change?*
Patterns seen in practice:

- **Adjacent churn** — upstream changed a line next to a mobile hunk (e.g. a
  version string in `common.gypi`): keep upstream's new value, keep the
  mobile hunk.
- **Both append at the same spot** (e.g. the tail of a gyp `conditions`
  list): keep both blocks, upstream's first.
- **Upstream restructured context the patch relied on** (e.g. a macro block
  the mobile diff sat inside was removed): re-apply only the mobile intent
  against the new structure.
- **Delete/modify** — a file we delete was modified upstream: the intent is
  still deletion → `git rm` the unmerged paths, continue.
- **Wholesale-replacement docs** (the fork `README.md` replaces the upstream
  remainder): resolve to ours.

A clean `git am` is **not** proof of semantic correctness: an upstream
restructure can merge cleanly yet leave a platform guard (`#endif //
TARGET_OS_OSX`) above code that needs it — caught only by the cross-compile.
Treat the full Build matrix as part of the upgrade loop, and re-check that
every platform guard (`TARGET_OS_OSX` / `__ANDROID__`) still encloses
everything it needs to.

Also:

- check `.github/workflows/` in `out/` for **new upstream workflows** the
  removal patch doesn't cover yet — delete-and-own them in the upstream-CI
  removal patch (`ci-remove-upstream-only-workflows-and-config.patch`); a
  `verify-patches` job asserts the materialized tree carries zero workflow
  files, so a missed one fails loudly.

Then regenerate and commit:

```sh
git -C out add -A && git -C out commit -m "resolve v24.19.0 conflicts"  # any shape
scripts/regenerate-patches.py out         # re-emits patches/ + syncs mobile-src/
# update expected-tree.txt to the hash the script prints
git add -A && git commit -m "upgrade: rebase patch series onto v24.19.0"
```

Open the PR. CI re-runs the reconstruction against a fresh upstream clone,
validates each patch individually, and — once merged — builds the full
matrix. The version bump and release are a separate step (below), so an
upgrade can land and be exercised before anyone decides to ship it.

## Release

Land the upgrade PR with the version header still at the old release's
values, then run **Cut release** (see [RELEASING.md](./RELEASING.md)) — it
bumps to `X.Y.Z-0` for the new base and opens the release PR; merging that
runs the whole gate chain and publishes. (If the upgrade PR bumps the
header itself, its merge becomes the release directly — both work.)

## Cross-major upgrades (e.g. v24 → v26)

Same procedure, larger blast radius: bump the base to the new major's LTS
tag and expect several patches to need rework or deletion (upstream may
have absorbed or obsoleted them — each patch body records *why* it exists
for exactly this decision). If both lines must stay releasable, branch the
recipe branch itself (e.g. `recipe-v24`) before bumping the base.
