# The patches model

nodejs-mobile is maintained as a **recipe for a source tree**, not as a fork
of one. This document explains the pieces, the rules that keep them
consistent, and why it is built this way. For the day-to-day loop see
[CONTRIBUTING.md](./CONTRIBUTING.md); for upstream bumps,
[UPGRADING.md](./UPGRADING.md).

## The pieces

| File / directory | Role |
|---|---|
| `upstream-base.txt` | the pinned `nodejs/node` release tag the patches apply to |
| `patches/*.patch` | one patch per **concern**, covering every upstream file the project modifies or deletes. Filenames are unnumbered — `series` alone records the order, so retiring or inserting a patch touches nothing else |
| `patches/series` | apply order |
| `patches/files.map` | `patch<TAB>path` for every file a patch owns — the partition that makes regeneration deterministic |
| `mobile-src/` | files with **no upstream counterpart**, tracked as plain files (build scripts, iOS framework project, test apps and harness) |
| `expected-tree.txt` | the git tree hash the reconstruction must produce |
| `scripts/prepare.sh` | recipe → source tree, with the hash check |
| `scripts/regenerate-patches.py` | source tree → recipe |

The split matters: a fork-only file never becomes a patch (a patch that
re-adds the same 400-line file on every upgrade is noise), and an upstream
file is never edited outside a patch (that is what makes the diff to upstream
readable and reviewable).

## The integrity check

`prepare.sh` = clone upstream at the base → `git am` the series → overlay
`mobile-src/` → compare the resulting git tree hash against
`expected-tree.txt`, and fail on mismatch.

A git tree hash is a Merkle checksum of an entire directory: paths, contents,
and executable bits. Two trees share a hash only if they are byte-for-byte
identical. Committing that hash next to the recipe closes a class of quiet
failures — a hunk applying with drifted context in the wrong place, whitespace
mangling from someone's git config, a lost `+x` bit, a fork-only file that
didn't survive the overlay, or an upstream tag being re-pointed at different
content. It does not assert that the tree is *good*, only that it is exactly
the tree whose recipe was reviewed.

It is enforced in three places: on every push (`verify-patches.yml`, against
a fresh upstream clone), inside every CI job before it compiles (the
`materialize` action), and at release time (the tag points at a materialized
commit with that tree).

**So: any intentional change to the recipe changes the product — run
`prepare.sh` or `regenerate-patches.py`, and commit the new hash with the
change.** Forgetting is safe; CI fails and prints the hash it computed.

## Patch rules

- **One concern per patch**, minimal diff, subsystem-prefixed subject
  (`build:`, `src:`, `deps,v8:`, `test:`). `files.map` records ownership.
- **The commit body explains *why*** — which platform limitation forces the
  change. On the next upgrade that is what tells you whether upstream has
  made the patch obsolete.
- **New upstream-file edits need an owner**: assign the file to an existing
  patch in `files.map`, or add a new `name.patch` to `series` (at the right
  position) + `files.map`. `regenerate-patches.py` refuses to guess.
- **New files default to `mobile-src/`**, unless they are upstream-coupled
  (e.g. a new file inside `deps/`), in which case give them to a patch.

Patch messages and `Co-authored-by:` trailers carry the attribution of the
contributors whose work each patch descends from — per patch, not blanket.
The upstreams the series draws on are janeasystems/nodejs-mobile and its
Andre Staltz-era successor (`main` here), the Acurast v24.5.0 port, and
heylogin's small-ICU branch. When a patch's diff changes, check whether its
trailers still match who wrote what survives in it.

## The series

One row per patch, in apply order (`patches/series`); patch files are named
after their commit subjects, and the short name in the first column is how the
prose here and in [TESTING.md](./TESTING.md) refers to them. Each patch's own
commit body carries the reasoning in long form, and the fork-only
`test-mobile-*` gates named below run in the curated device-test list on both
device legs.

| Patch | What it changes | Why |
|---|---|---|
| configure wrappers | `android_configure.py`, `configure.py`: dest-os plumbing, host CC/CXX, opt-in sccache wrap, full/lite flavor switch | gyp must be told about ios/android; host tools need a native compiler in a cross-build; wrapper-level so `configure.py` stays nearly upstream-clean |
| common.gypi | Apple xcode_settings per toolset, deployment targets; Android build-id + lite-only section GC | base platform settings gyp lacks for mobile; Mach-O gets an LC_UUID automatically so only ELF/Android needs `--build-id` |
| node.gyp/node.gypi | Android shared / iOS static library targets, `NODE_MOBILE` define, no cctest/executable on mobile | the shape of the shipped artifacts (`libnode.so`, `NodeMobile.xcframework`) |
| v8 gypfiles | host/target toolset settings, arch selection (PR-57748 guards) | mksnapshot/torque must build for the host while V8 builds for the phone |
| gyp generators | make/ninja treat `ios` like `mac` (xcode_emulation), simulator/device SDK switch | gyp has no built-in notion of an iOS make build |
| node.cc guards | `TARGET_OS_IPHONE`/`__ANDROID__` guards; POSIX credentials enabled on Android API ≥ 21 | mobile OSes forbid or lack the guarded facilities |
| credentials | drop setuid/setgid/setgroups native methods on Android; getgrnam shim for initgroups; `SafeGetenv()` skips the privilege heuristic on `NODE_MOBILE` builds | the app sandbox never permits credential changes; bionic lacks `getgrnam_r`; a zygote-forked app looks privileged to upstream's heuristic, which would decline every embedder-set variable read through `SafeGetenv()` (see [EMBEDDING.md](./EMBEDDING.md#two-read-paths-and-why-it-matters)). Gates: `test-mobile-credentials`, `test-mobile-node-path` |
| env clone | `KVStore::Clone()` skips an unresolvable variable instead of failing | bionic strips e.g. `LD_PRELOAD` from starting apps; a default-env Worker would otherwise die. Gate: `test-mobile-worker-env-clone` |
| version key | `process.versions.mobile` | the sanctioned way to detect a mobile build; `process.version` stays upstream. Gate: `test-process-versions` |
| crypto trust | `TARGET_OS_OSX` fences around macOS-only trust-settings API; iOS evaluates candidates via `SecTrustEvaluateWithError` | an iOS build doesn't link the macOS API. Gate: `test-mobile-system-ca` |
| libuv | Android `copy_file_range` guard, iOS cpu-frequency guard, uv.gyp host sources | desktop assumptions in libuv that break on mobile kernels/SDKs |
| v8 trap handler | `V8_TRAP_HANDLER_SUPPORTED false`; deletes upstream's `android-patches/` file | V8's own comment: enabling under Android signal handling needs security review; useless under jitless iOS. Upstream's configure-time `patch -f` mechanism mutates the tree mid-build and never ran for iOS — baked in instead |
| c-ares | darwin config: `HAVE_SYS_RANDOM_H` guarded to macOS | the iOS SDK has no `<sys/random.h>`; c-ares falls back to `arc4random_buf` |
| deps gyp | zlib / openssl-no-asm conditionals | deps gypfiles that don't know the mobile OSes |
| test harness | `common.isAndroid/isIOS`, test.py arch→system mapping, device `.status` sections | lets upstream's own runner drive a phone and skip whole unsupported categories |
| test adaptations | minimal per-test guards + the fork-only `test-mobile-*` tests | keeps upstream tests runnable on-device; wholesale rewrites are rejected by `audit-test-edits.sh` in CI |
| README/ignores | short README pointing at the recipe branch; build-output ignores | a release tag is a materialized tree — its README should say so; the dev loop's git operations must not sweep build outputs |
| upstream CI removal | deletes every upstream workflow and upstream-only config | a ref carrying the materialized tree must never run upstream CI here — even inert workflows go, since their triggers can change on a bump; verify-patches asserts the tree carries zero workflow files |
| WebAssembly polyfill | bundles polywasm, installed only when the engine has no WebAssembly | jitless iOS V8 has no wasm, which kills `fetch()` (undici's llhttp is wasm). Gate: `test-mobile-fetch` + the jitless host gates |

## Branches

| Branch | Role |
|---|---|
| `recipe` | the project: the recipe, the tooling, the docs, and all CI |
| `mobile/v24` | frozen — a fully-materialized Node 24 tree, superseded by this branch |
| `main` | frozen — the legacy Node 18 line |

Release tags (`vX.Y.Z-R`) point at **materialized full-source commits**, so
every release stays browsable as a complete tree even though no branch
carries one.

## Why this shape

The two obvious alternatives both cost more than they look. A full fork that
merges each upstream release produces unreviewable multi-million-line import
commits and cannot be bisected. A rebased in-tree patch *stack* keeps the
changes legible but puts every edit through history rewriting — fix-ups
accumulate, restoring atomicity means interactively rebasing the whole stack,
and force-pushes invalidate review state.

The patches model keeps the legibility and drops the history management.
Patches are ordinary files: editing one is a normal commit with a reviewable
diff, no rebase, no force-push. What it deliberately does *not* claim to fix
is upstream conflicts — a conflicting upstream change is the same work
either way. What it changes is that the work is isolated to one small patch,
and that resolving it is an edit rather than a rebase.

The cost is real and worth stating: the source tree is not directly
browsable here (run `prepare.sh`, or read a release tag), and GitHub renders
patch files as text rather than as diffs.
