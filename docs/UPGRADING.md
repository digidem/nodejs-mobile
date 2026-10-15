# Updating nodejs-mobile to a newer upstream Node.js

Bumping to a newer upstream Node.js release means re-basing the patch
series onto the new tag. There is no branch rebasing and no force-pushing —
the patches are files, and the upgrade is an ordinary reviewable PR.

Expect a handful of small conflicts resolvable in minutes — plus,
occasionally, one that only the compile catches (see the warning below).

## Re-base the series

```sh
$EDITOR upstream-base.txt                 # bump the tag, e.g. v24.20.0 (don't commit yet)
scripts/prepare.sh                        # clone new base + apply series
```

`prepare.sh` stops at the first patch that no longer applies and prints a
summary of the unmerged paths. Resolve **in `out/`**, `git -C out am
--continue`, then resume the rest of the series with
`scripts/apply-series.sh out` (see [Resuming](#resuming-after-a-conflict)).
Each conflict comes down to one question: *what does this patch intend, and
what did upstream change?* Patterns seen in practice:

- **Adjacent churn** — upstream changed a line next to a mobile hunk (e.g. a
  version string in `common.gypi`): keep upstream's new value, keep the
  mobile hunk.
- **Both append at the same spot** (e.g. the tail of a gyp `conditions`
  list): keep both blocks, upstream's first.
- **Upstream restructured context the patch relied on** (e.g. a macro block
  the mobile diff sat inside was removed): re-apply only the mobile intent
  against the new structure.
- **Upstream absorbed the mobile hunk** — upstream now does what the patch
  did, often more generally: drop the hunk, and trim the paragraph of the
  patch header that explained it (edit the `.patch` header, then
  regenerate). Recheck the `Co-authored-by:` trailers against what remains.
  v24.22.0 wrapped `--experimental-wasm-jspi` in `#if V8_ENABLE_WEBASSEMBLY`
  and started defining that macro for node's own targets in `common.gypi`;
  iOS builds V8 in lite mode, so that retired our iOS-only guard. Before
  dropping one, trace the chain on the new base — the old header may say
  why upstream's spelling would not have worked before.
- **Delete/modify** — a file we delete was modified upstream: the intent is
  still deletion → `git rm` the unmerged paths, continue. The conflict
  summary prints the one-liner.
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
  `regenerate-patches.py` rejects the deletion as owned by no patch.
  `apply-series.sh` lists any it finds, and a `verify-patches` job asserts
  the materialized tree carries zero workflow files. The reverse also
  happens: when upstream deletes a file a `files.map` line names (v24.22.0
  dropped `commit-lint-problem-matcher.json`), remove that line.
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

```
error: sha1 information is lacking or useless (README.md).
error: could not build fake ancestor
```

is not a conflict. `--3way` needs the *pre-image* blob the patch header
records, and `prepare.sh` clones `--depth 1`, so the clone has nothing to
merge against for files upstream touched since the old base. The scripts
fetch the old base for you when it is derivable — the committed
`upstream-base.txt`, while your bump is still uncommitted — or from
`OLD_BASE=<tag>`. If you see this error, set `OLD_BASE` and re-run
`scripts/apply-series.sh out`.

### Resuming after a conflict

`prepare.sh` refuses to run when `out/` exists, so it cannot resume. Once
you have resolved a conflict and run `git -C out am --continue`:

```sh
scripts/apply-series.sh out
```

It skips every patch whose subject is already in `out/`'s history (or
starts at `--from <patch>`), applies the rest, commits the `mobile-src/`
overlay if it hasn't been, and compares the tree hash — informational
here, since the hash moves with the upgrade. The overlay is not optional:
without it, `regenerate-patches.py` reads every fork-only file as deleted.

Work with `git -C out …` rather than `cd out`, and give `git -C out am`
absolute patch paths — it resolves relative ones against `out/`.

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
scripts/triage-new-tests.py out v24.20.0 v24.22.0
```

It covers added tests and the added lines of modified ones — an existing
test can gain a subtest that spawns a child or a `// Flags:` entry iOS
rejects (v24.22.0 did both, to `test-fs-glob` and
`test-internal-webidl-buffer-source`). It drops tests the platform's
`.status` block already matches and prints one line per suspect with its
category, the platforms still open, the matching source line, and any
top-level `common.skip()` guard. A minor release can add hundreds of tests;
most need nothing. Read each suspect against these causes:

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
- **V8 flags iOS doesn't have** — iOS builds V8 in lite mode, which compiles
  out WebAssembly, so a `// Flags: --experimental-wasm-*` header fails with
  `bad option` before the test runs. Skip on iOS only.
- **Self-skipping** — a test that ends at `common.skip()` scores PASS, so it
  needs no entry. This is why v24.20.0's ~250 new QUIC tests are absent from
  `parallel.status`: the mobile build doesn't pass `--experimental-quic`, so
  `hasQuic` is false and each one skips itself.
- **Already covered by a glob** — check before adding. `test-cli-*`,
  `test-eslint-*` and `test-child-process-*` are skipped wholesale on both
  platforms; `test-debugger-probe-*` is a glob on Android but an itemized
  list on iOS, so a new member of that family needs an iOS entry only.
- **Execs a non-node binary** (`mkfifo`, `sh`) — a judgement call. Android
  ships toybox, so it may work; a real iOS device can't spawn at all.
  Existing `mkfifo` tests are skipped; say which way you went in the PR.
- **Expects a libstdc++ errno** — mobile links libc++, like macOS, so code
  built on `std::filesystem` reports macOS's errno: `rmSync` on a read-only
  directory gives `ENOTEMPTY`, not `EACCES`. When the test already
  special-cases `common.isMacOS`, extend that condition with an anchored
  `common.isAndroid || common.isIOS` guard rather than skipping the file.
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

Unlike the repo's usual short-prose PRs, an upgrade PR uses headings, so a
reviewer can find the test decisions and tell routine ones from the ones
that need thought:

- **Conflicts** — each one and how it was resolved.
- **Upstream changes absorbed** — mobile hunks dropped because upstream now
  covers them, and the chain that proves it; new or removed workflows and
  `files.map` lines; new build targets.
- **Test changes**, in three groups:
  - *Clear-cut skips* — spawns a child node, permission sandbox, iOS
    lite-mode flags.
  - *Judgement calls* — external binaries, platform errno differences, an
    anchored guard chosen over a skip (or the reverse).
  - *Failures that may indicate a mobile issue* — anything the suite
    surfaced that none of the above explains; say what was investigated
    before it was skipped, or why it was not.
- **Verification** — reconstruction, audits, what was built locally.
- **Manual steps** — the `upstream-base` push below.

CI re-runs the reconstruction against a fresh upstream clone,
validates each patch individually, and — once merged — builds the full
matrix. The version bump and release are a separate step (below), so an
upgrade can land and be exercised before anyone decides to ship it.

Because the PR moves `upstream-base.txt`, it also runs the **full device
suite** on both platforms and cannot merge until that is green (the curated
gate is an allow-list, so it cannot see tests upstream just added — they
would otherwise surface on the nightly or at release). Expect the PR to take
substantially longer than a normal one. → [TESTING.md](./TESTING.md)

A bump also needs this fork's `upstream-base` branch moved to the new tag.
That branch is load-bearing rather than informational: the release tag is
pushed from a shallow clone whose history stops at the base, so the remote
can only accept it if it already holds the base and its ancestry. Don't
delete it, and don't leave it behind — `publish` `needs:` the `upstream-base`
job, so a release run would otherwise get as far as tagging and stop there.

Moving it is a manual maintainer step. CI only checks it, because the push
carries upstream's own `.github/workflows/` files and GitHub refuses those
from `GITHUB_TOKEN` without the `workflows` permission — a scope a workflow
cannot grant itself. Automating it would mean giving CI a PAT or deploy key
with write access to this repo, which is not worth the exposure for a push
taken once per upgrade. The `upstream-base` job prints the exact commands
when it fails; they amount to:

```sh
git fetch https://github.com/nodejs/node.git refs/tags/v24.20.0
git push --force --no-follow-tags digidem <sha-of-v24.20.0>:refs/heads/upstream-base
```

Push it any time from the bump PR onwards — nothing reads the branch except
a release run — then re-run the job.

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
