# Build Instructions

nodejs-mobile builds one native library per target, and **each target builds on
one host OS only:**

| Target  | Output                       | Build host           |
|---------|------------------------------|----------------------|
| Android | `libnode.so` (per ABI)       | **Linux only**       |
| iOS     | `NodeMobile.xcframework`     | **macOS only** (Xcode) |

> **Why Android can't be built on macOS.** node's bundled gyp archives static
> libs as GNU thin archives (`ar crsT … @file-list` response files) and links
> the cross-build's *host* build-tools (e.g. `node_js2c`) with the ELF-linker
> option `-Wl,--start-group`. Apple's `/usr/bin/ar` and `ld64` support neither,
> so a macOS host fails — first at the archiver (`ar: @…ar-file-list: No such
> file or directory`), and even with `AR_host` pointed at the NDK's `llvm-ar`,
> then at the host link (`ld: unknown options: --start-group`). `--start-group`
> is ELF-only and no Mach-O linker implements it, so there is no drop-in macOS
> fix. This is a property of node's build system, not the mobile patches, and it
> affects `full` and `lite` identically. Build Android on Linux (CI uses
> `ubuntu-24.04`).

## Python (both targets)

Both build paths run gyp / V8 code generation under Python. Use a **Python 3.13**
(3.12 also works) venv with `setuptools` installed — gyp-next declares
`setuptools` as a build-time dependency and a bare venv does not bundle it. CI
does the same:

```sh
python3.13 -m venv .venv
. .venv/bin/activate
pip install setuptools
```

---

## Android — build on Linux

### Prerequisites

```sh
sudo apt-get install -y build-essential git gcc-multilib g++-multilib
```

Install Android NDK **r27d** (`27.3.13750724`) via the SDK Manager (the
`ubuntu-24.04` GitHub runner already ships an NDK 27 at `$ANDROID_NDK_LATEST_HOME`):

```sh
sdkmanager "ndk;27.3.13750724"
```

### 1) Get a source tree

This repository holds the recipe, not the source. Generate a tree from it:

```sh
git clone -b recipe https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile && scripts/prepare.sh && cd out
```

All the build commands below run from that `out/` directory. A release tag
(`vX.Y.Z-R`) already *is* a materialized tree, so checking one out works too.

### 2) Build with the helper script

```sh
./tools/android_build.sh <ndk-path> <sdk-version> [arch]
```

- `<ndk-path>` — the installed NDK, e.g. `~/Android/Sdk/ndk/27.3.13750724`
- `<sdk-version>` — minimum Android SDK version as a number, e.g. `24`
- `[arch]` — `arm`, `arm64`, or `x86_64`; omit to build all three.

```sh
./tools/android_build.sh ~/Android/Sdk/ndk/27.3.13750724 24
```

Output: `out_android/<abi>/libnode.so` for each ABI (`armeabi-v7a`, `arm64-v8a`,
`x86_64`).

To configure and build a single architecture manually instead:

```sh
./android-configure <ndk-path> <sdk-version> <arch>
make
# -> out/Release/lib.target/libnode.so
```

---

## iOS — build on macOS

### Prerequisites

Xcode with the Command Line Tools (`xcode-select --install`, which also installs
`git`).

### 1) Get a source tree

As above — `scripts/prepare.sh`, or a release tag. Commands run from `out/`.

### 2) Build with the helper script

```sh
./tools/ios_framework_prepare.sh [arm64|arm64-simulator]
```

With no argument it builds **both** arm64 slices — device (`iphoneos`) and
simulator (`iphonesimulator`) — and combines them. The script configures gyp to
build Node.js and its dependencies as static libraries with V8 set to run
jitless (Apple's no-JIT rule), staging the libs through
`tools/ios-framework/bin/` into the `tools/ios-framework/NodeMobile.xcodeproj`
project. Because iOS can never JIT, the compiled optimizer tiers are removed
outright in **both** flavors: `v8_enable_turbofan=0` swaps V8's compiler for
upstream's `turbofan-disabled.cc` stub (mksnapshot keeps the real backend to
generate builtins), `--v8-disable-maglev` drops the mid-tier, and the
snapshot-generator (`libv8_initializers`) and gtest libraries — dead weight the
`-all_load` framework link used to force in — are excluded from the link. Pass `arm64` or `arm64-simulator` to build only one slice during
development. (x86_64 / Intel-simulator support was dropped for v24: Intel Macs
are EOL and Apple Silicon runs the arm64 simulator natively.)

Output: **`out_ios/NodeMobile.xcframework`** (device + simulator arm64 slices).

---

## The lite variant

To build it instead of the default, set `NODEJS_MOBILE_FLAVOR=lite` on either
target's build command.

The build ships in two flavors (selected by `NODEJS_MOBILE_FLAVOR`, default
`full`). **`full`** is the general-purpose binary all consumers get. **`lite`**
is a smaller binary for consumers that don't need the full feature set, built by
layering feature-drops on top of the full configure — so the full binary and its
test gate are unchanged.

What `lite` drops (all already-available upstream `configure` flags, so no extra
patch-stack surface):

| Cut | Why it can be dropped |
|---|---|
| `--without-amaro` (TS type-stripping) | for consumers shipping plain `.js` |
| `--without-inspector` | not used in production |
| `--without-sqlite` | for consumers using the `better-sqlite3` addon, not `node:sqlite` |
| `--with-intl=none` (no ICU) | for consumers that use no `Intl.*` — verify against your own dependency tree (a dependency may reference `Intl` from a code path you never call) |
| **iOS only:** `--v8-lite-mode` | drops the compiled JIT + V8 WASM engine, both **dead on iOS** (it runs jitless; WebAssembly is served by the bundled polywasm polyfill — see [FAQ](./FAQ.md#does-fetch-work-what-about-webassembly)). This is the big lever. |

Dead-code stripping (`--gc-sections`) applies to **both** Android flavors: the
linker only discards unreferenced sections, so it costs no functionality.

Measured shipping sizes (arm64, after symbol strip):

- **iOS:** the dead-code removal above cut the lite device slice
  **54.5 → 33.8 MB** (−38%); full shrinks by the same ~20 MB since every cut
  is flavor-neutral (its size is measured by the release CI).
- **Android:** **61.5 MB (full)** / **45.6 MB (lite)** with gc-sections on
  both flavors; no
  `--v8-lite-mode` (Android keeps the JIT and V8's native WASM for undici).

`build-id` (`-Wl,--build-id=sha1`) is emitted on the Android `libnode.so` in
**both** flavors so crash reporters (e.g. Sentry) can symbolicate native
crashes. The safeguard for `intl=none` is running your own application's test
suite against the lite binary — it catches `Intl` breakage from future
dependency changes.


---

## The CI compiler cache

CI compiles Node from scratch in eleven jobs per run, so it keeps a shared
compiler cache: [sccache](https://github.com/mozilla/sccache) against a
Cloudflare R2 bucket, wired in `.github/workflows/build.yml`. R2 rather than
the GitHub Actions cache because Actions' 200-uploads-per-minute-per-repo
limit cannot serve this workload at any tuning — the long comment on
`build-android`'s `sccache stats` step has the measurements.

The thing to understand before touching any of it: **an sccache entry is a
claim the reader never verifies.** The key is a hash of the preprocessed
source and the compiler; the value is the object file that is supposed to
result. Nothing re-derives it on the way out. Whoever can write to the bucket
can therefore choose the object files a later build links — which, for the
release run, means choosing the bytes that ship. Two measures follow from
that, and they are independent on purpose.

### 1. The publish path builds cold

Every compiling job (`build-android`, `build-ios`, `smoke-host`) runs
[`.github/actions/release-check`](../.github/actions/release-check/action.yml)
before `materialize` and asks whether this run is a release — or a
`release-dryrun:` rehearsal, which must build the same way to be a rehearsal
at all. When it is:

- sccache is never installed, and nothing wraps the compiler: Android's
  `NODEJS_MOBILE_SCCACHE` opt-in is left empty, iOS never writes its
  `CC`/`CXX` wrapper scripts, `smoke-host` uses the bare `cc`/`c++`.
- the R2 credentials are blanked, so a release build has no credential for
  the shared cache anywhere in its environment.
- the `libnode` Actions cache is **restored** by no one — that step is
  skipped, though the job still *saves*, so the first PR after a release
  finds a warm key. (Today the version bump changes `HEAD:src` and misses
  that key anyway. Skipping the restore is what makes it a property of the
  workflow rather than a coincidence.)

So a poisoned cache object has no path to a shipped artifact. The worst it
can do is waste CI time or corrupt a dev/test binary. This is why the measure
is worth its cost: it moves cache poisoning out of the supply chain entirely,
rather than making it harder.

The cost is a cold release: **~1.5–3 h** for the Android matrix, ~82 min for
`smoke-host`, both parallel, a few times a year. See
[RELEASING.md](./RELEASING.md#a-release-run-builds-cold).

`smoke-host` is included even though it ships nothing. It gates `publish`, so
a subverted host binary is a host binary that can be made to pass the tests
standing between a release and the tag.

### 2. Read and write are split by credential

Only a push to `recipe` may write. This is enforced by which credential the
job gets, not by any expression in the workflow file:

| GitHub Environment | R2 token | Protection |
|---|---|---|
| `sccache-read` | Object Read only | none — this is the default for PRs and dispatches |
| `sccache-write` | Object Read & Write | deployment branch rule: `recipe` only |

Both hold the token under the **same secret names** (`R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`), and each compiling job selects one by event:

```yaml
environment:
  name: ${{ github.event_name == 'push' && github.ref == 'refs/heads/recipe' && 'sccache-write' || 'sccache-read' }}
  deployment: false
```

Same names is the point. No expression in `build.yml` names the write token,
so no edit to `build.yml` — which a PR can make, and which runs in that PR —
can hand it to a PR run. Asking for `sccache-write` from any other branch is
refused by GitHub before the job starts. Poisoning the cache therefore
requires landing a commit on `recipe`.

`SCCACHE_S3_RW_MODE` (workflow env) is set to `READ_ONLY` off `recipe` as
well. That one *is* workflow-side and thus editable in a PR, which is exactly
why it is not the enforcement — it exists so sccache doesn't attempt ~2500
doomed `PUT`s per job, plus the probe object it writes at server start, when
the token would refuse them anyway. An sccache too old to know the variable
ignores it and falls back to failed writes, which `SCCACHE_ERROR_LOG` already
reports; no regression either way.

`R2_ACCOUNT_ID` (endpoint) and `vars.R2_BUCKET` stay at repository scope —
neither is a capability.

### Setting it up

On the Cloudflare side, R2 → Manage API tokens, two tokens scoped to the
bucket: one **Object Read only**, one **Object Read & Write**. On the GitHub
side, Settings → Environments:

1. `sccache-read` — no protection rules. Secrets: `R2_ACCESS_KEY_ID`,
   `R2_SECRET_ACCESS_KEY` = the **read-only** token.
2. `sccache-write` — **add the deployment branch rule for `recipe` before
   adding the secrets.** Same two secret names = the **read-write** token.
3. Delete `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` at repository scope, so
   each token lives in exactly one place. (An environment secret shadows a
   repository secret of the same name, so leaving them would not break
   anything — it would just make the write token reachable from a PR again,
   silently.)

Both environments are auto-created on first reference if they don't exist, so
a missing branch rule **fails open**: the workflow runs, and the write token
simply isn't restricted. The rule is the whole mechanism; check it after any
Settings change.

### The daily credential probe

`.github/workflows/cache-credentials.yml` checks both tokens daily with plain
SigV4 requests against the bucket: GET of a never-written key (404 proves the
request authenticated), then PUT and DELETE — expected to succeed for
`sccache-write` (with a byte-identical read-back) and to be refused with 403
for `sccache-read`. The two matrix legs run byte-identical code; only the
expected statuses differ, so a denial cannot be an artifact of code the other
leg doesn't run. sccache itself is not involved — the tokens are what is under
test, and every build exercises the sccache integration anyway.

Run it by hand (Actions → Cache credentials → Run workflow) right after
changing a token or an environment. Dispatching it from a ref other than
`recipe` also tests the deployment branch rule, and the `sccache-write` leg
comes out red either way — what matters is the message. Refused by GitHub
before any step ran (a protection-rules annotation): the rule works. Failed
by its own ref guard: the leg actually ran, meaning **the rule is missing**
and the write token is obtainable from arbitrary branches — the fail-open
case described above, caught rather than reported as a healthy token. A
scheduled run cannot test this; it always runs on the default branch, where
the rule passes.

### Gotchas

- The conditionals are all written `cold != 'true' && <cache on> || <cache
  off>`, never `cold == 'true' && <cache off> || <cache on>`. GitHub's ternary
  idiom falls through to the `||` branch whenever the `&&` branch is falsey,
  and `''` is falsey — so the natural-reading form silently enables the cache
  on exactly the runs that must not have it.
- Android's opt-in is tested with `os.environ.get()`, which is truthy for
  `'0'`. Clear it to the empty string, not to `'0'`.
- `release-check` must run **before** `./.github/actions/materialize`: it
  reads `mobile-src/src/node_mobile_version.h`, and materialize replaces the
  workspace with the generated tree.
- The build jobs call the action directly rather than `needs:`-ing the
  `release-check` *job*. That job is deliberately skipped off
  push-to-`recipe`, and a job that needs a skipped job is skipped too — the
  whole build matrix would vanish on PRs.
