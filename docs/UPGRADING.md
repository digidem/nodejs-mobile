# Updating nodejs-mobile to a newer upstream Node.js

Bumping to a newer upstream Node.js release means re-basing the patch
series onto the new tag. There is no branch rebasing and no force-pushing —
the patches are files, and the upgrade is an ordinary reviewable PR.

Expect a handful of small conflicts resolvable in minutes — plus,
occasionally, one that only the compile catches (see the warning below).

## Re-base the series

```sh
$EDITOR upstream-base.txt                 # bump the tag, e.g. v24.20.0
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
  removal patch doesn't cover yet — `git rm` them in `out/` *and* add each
  path to `patches/files.map` against the upstream-CI removal patch
  (`ci-remove-upstream-only-workflows-and-config.patch`), or
  `regenerate-patches.py` rejects the deletion as owned by no patch. A
  `verify-patches` job asserts the materialized tree carries zero workflow
  files, so a missed one fails loudly.
- add `.status` entries for the tests upstream just added — see [new upstream
  tests](#new-upstream-tests) below.
- watch for upstream **splitting a build target**. gyp resolves the new
  dependency on Android, but the iOS framework links a hand-maintained list of
  archives — `outputs_common` in `mobile-src/tools/ios_framework_prepare.sh`
  plus four entries in the `NodeMobile.xcodeproj` pbxproj — so a new
  `static_library` shows up as undefined symbols at `Ld`, long after every
  compile has passed. v24.19.0 split `libnode_base` out of `libnode`;
  v24.20.0 split `libncrypto_engine` out of `libncrypto`. If an iOS leg
  fails with `Undefined symbols` naming a class you did not touch, check
  `deps/*/*.gyp` for a target that did not exist at the old base. Note the
  pbxproj is `.gitignore`d inside the tree, so staging it needs `git add -f`.

### `sha1 information is lacking or useless`

A patch that stops with

```
error: sha1 information is lacking or useless (README.md).
error: could not build fake ancestor
```

has not conflicted. `--3way` needs the *pre-image* blob the patch header
records, and `prepare.sh` clones `--depth 1`, so `out/` holds only the new
tag's blobs — for any file upstream touched since the old base, git has
nothing to merge against. Fetch the base you are moving off to supply them:

```sh
git -C out fetch --depth 1 origin tag v24.19.0
```

Retry the patch and it either applies or fails as an ordinary content
conflict you can resolve. Do this before editing anything by hand: with the
old blobs present, `git am --3way` absorbs most upstream drift on its own.

### Finishing the series by hand

`prepare.sh` refuses to run when `out/` exists, so it cannot be re-run to
resume. Once you have resolved the conflict, land it and apply the rest of
`patches/series` yourself with the same invocation the script uses:

```sh
git -C out am --continue
git -C out am --3way --keep-cr --whitespace=nowarn patches/<each remaining>.patch
```

Then redo step 3, the `mobile-src/` overlay, which never ran. It is not
optional — without that commit `out/` is upstream plus patches, and
`regenerate-patches.py` reads every fork-only file as deleted:

```sh
( cd mobile-src && git ls-files -z --cached --others --exclude-standard . ) > /tmp/manifest
( cd mobile-src && tar cf - --null -T /tmp/manifest ) | ( cd out && tar xf - )
git -C out add -f --pathspec-from-file=/tmp/manifest --pathspec-file-nul
git -C out commit -m "mobile: fork-only files (mobile-src overlay)"
```

### Regenerate and commit

```sh
git -C out add -A && git -C out commit -m "resolve v24.20.0 conflicts"  # any shape
scripts/regenerate-patches.py out         # re-emits patches/ + syncs mobile-src/
# update expected-tree.txt to the hash the script prints
git add -A && git commit -m "upgrade: rebase patch series onto v24.20.0"
```

Reconstruction from a clean clone is what CI checks, so check it here too:
`rm -rf /tmp/verify && scripts/prepare.sh /tmp/verify` must print `OK` on the
hash you just committed.

## New upstream tests

Edit `test/*/*.status` in `out/`, before the regenerate step above.

The full suite is a deny-list, so every test a release adds runs on device
the moment the base moves — and the suite gates the merge. Work out what
needs skipping *before* pushing rather than reading it off a red run:

```sh
git -C out diff --name-status v24.19.0 v24.20.0 -- test/parallel test/sequential | grep '^A'
```

A minor release can add hundreds. Most need nothing. Triage by cause:

- **Spawns a child node process** — cannot pass on Android, where
  `process.execPath` is `app_process64`, so the child SIGABRTs (its stderr
  comes back as `Error changing dalvik-cache ownership`). Skip. Grepping for
  `child_process` is **not** enough, and this is where triage actually goes
  wrong: a test can spawn through `common.spawnPromisified` destructured off
  `require('../common')`, which never names `child_process`, or through
  `node:test`'s `run({ isolation: 'process' })`, which spawns inside the
  runner. Grep for `process.execPath`, `spawnPromisified` and `isolation`
  too, and read the test titles — `'…forwarded from child processes'` is the
  giveaway that greps miss.
- **Runs under `--permission` with no `--allow-fs-write`** at exit — read the
  `// Flags:` header, and watch for a test that starts with the permission
  and calls `process.permission.drop('fs.write')` (or `'fs'`) partway
  through. The verdict write is denied either way. Skip.
- **Self-skipping** — a test that ends at `common.skip()` scores PASS, so it
  needs no entry. This is why v24.20.0's ~250 new QUIC tests are absent from
  `parallel.status`: the mobile build doesn't pass `--experimental-quic`, so
  `hasQuic` is false and each one skips itself.
- **Already covered by a glob** — check before adding. `test-cli-*`,
  `test-eslint-*` and `test-child-process-*` are skipped wholesale on both
  platforms; `test-debugger-probe-*` is a glob on Android but an itemized
  list on iOS, so a new member of that family needs an iOS entry only.
- **Everything else** — leave it to run. The suite is the measurement.

A child-process spawner fails the Android suite outright, and on the iOS
*simulator* it is **flaky rather than passing**: `posix_spawn` is permitted
there, so it often works and sometimes does not — the same test failed the
Android suite, passed one iOS run, then failed the next. Skip these on both
platforms. A green iOS shard is not evidence the test is sound; it cannot
work on a real device either way, which is why `parallel.status` already
carries a block saying this class is "not coverage worth keeping".

`// Flags:` headers *are* honoured on device (the proxy forwards the whole
argv `test.py` hands it), so a new flag-gated feature needs no special
handling.

Put entries in the cause-named section that matches, on both platforms unless
the cause is platform-specific, in the block's existing sort order. Leave the
blocks headed *"measured on a full device sweep"* alone: those record what a
run actually observed, and an inferred entry filed there makes the heading a
lie. Say in the PR that the new entries are inferred and the suite is what
confirms them.

## Open the PR

CI re-runs the reconstruction against a fresh upstream clone,
validates each patch individually, and — once merged — builds the full
matrix. The version bump and release are a separate step (below), so an
upgrade can land and be exercised before anyone decides to ship it.

Because the PR moves `upstream-base.txt`, it also runs the **full device
suite** on both platforms and cannot merge until that is green (the curated
gate is an allow-list, so it cannot see tests upstream just added — they
would otherwise surface on the nightly or at release). Expect the PR to take
substantially longer than a normal one. → [TESTING.md](./TESTING.md)

Merging the bump also moves this fork's `upstream-base` branch to the new
tag, via the `upstream-base` job. That branch is load-bearing rather than
informational: the release tag is pushed from a shallow clone whose history
stops at the base, so the remote can only accept it if it already holds the
base and its ancestry. Don't delete the branch, and if the job fails, fix it
before cutting a release — `publish` `needs:` it, so a release run would
otherwise get as far as tagging and stop there.

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
