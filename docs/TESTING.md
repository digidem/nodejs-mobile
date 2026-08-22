# Testing nodejs-mobile

How the mobile test harness works, what CI runs, and how to run the tests
locally on an Android emulator, an iOS simulator, or a physical device.

## How a test PASSes

The harness runs the **real upstream `tools/test.py`** on the host, but points
its `node` executable at a per-platform **proxy script**. For each test case the
proxy relaunches the testnode app on the device (`am start` on Android, `xcrun
simctl launch` on an iOS simulator, `devicectl` on an iOS device), passing the
test-file path and a unique per-launch token. The app runs the file in-process
via the embedded `node_start()`; when node returns, native code writes a `PASS`
/ `FAIL` verdict (the real exit code) to a per-launch file in the app's private
sandbox (`result-<token>.txt`). The proxy reads that file back and reports to
`test.py`.

The verdict rides a **durable sandbox file, never the log stream** — `logcat`
and `simctl --console` are shared, lossy streams that truncate and ring-buffer-
evict, so a dropped line would read as a false failure. The token prevents a
stale file or a spawned grandchild from being mis-attributed.

A test that calls `process.exit()` never unwinds back to the native caller —
libc `exit()` runs first — so the native write never happens. The app therefore
also drops a small `exit-verdict-hook.js` into its sandbox at launch and
preloads it via `NODE_OPTIONS=--require` (which stays out of
`process.execArgv`), registering a `process.on('exit')` handler that writes the
real code. The handler is confined to the main thread, so a worker calling
`process.exit()` cannot overwrite the parent's verdict, and it `require()`s
nothing until the process is already exiting, so it adds no entries to
`process.moduleLoadList` (which `test-bootstrap-modules` asserts on exactly).
The `atexit` `FAIL` fallback remains for the cases that reach neither path — a
crash or an abort — and checks for an existing verdict file rather than only its
own flag, so it cannot clobber what the hook just wrote.

This matters far beyond tests that exit deliberately: `common.skip()` ends in
`process.exit(0)`, so every test that self-skips at runtime — no QUIC, no
crypto, Windows-only, debug-build-only — depends on the hook to be scored
correctly. That is also why it is installed unconditionally: which tests need
it is decided at runtime, and its only observable trace is one extra
`process.on('exit')` listener. (A test that calls
`process.removeAllListeners('exit')` would drop the hook and score FAIL —
none currently does.)

A run that produces no verdict file at all is a FAIL, and the proxy says which
kind: the Android one polls the app process alongside the file, so a native
crash (SIGSEGV/SIGKILL never reaches the `atexit` fallback, so no verdict is
ever written) reports `crashed (process gone after Ns, no verdict)` as soon as
the process dies, while `hung (no verdict after full TIMEOUT)` means it was
still alive at the deadline.

**Caveat:** `test-process-getactiveresources` asserts the exact set of active
handles, which depends on what stdout *is*: no handle when it's a file (how
`tools/test.py` runs every test), a `PipeWrap`/`TTYWrap` on a pipe or terminal.
Running that one file by hand fails on stock upstream node the same way — run
it through `tools/test.py`.

## What CI runs

| Workflow (on the `recipe` branch) | Runner | Trigger | Proves |
|---|---|---|---|
| `verify-patches.yml` → `verify` | ubuntu | PR · push `recipe` | the patch series + `mobile-src/` reconstruct the recorded tree byte-for-byte from a fresh upstream clone |
| `verify-patches.yml` → `patch-stack-configure` | ubuntu | PR · push `recipe` | every patch passes `./android-configure` individually (~1 min/patch) |
| `verify-patches.yml` → `tree-diff` | ubuntu | PR | *not a gate* — publishes the diff between the base and head **materialized trees** as a job summary + artifact, so review isn't a diff-of-a-diff |
| `build.yml` → `release-notes` | ubuntu | PR · push `recipe` | the first `docs/CHANGELOG.md` section is the one `publish` will ship — this version of record, cut-release `_TODO_` stub filled in. Gates `ci-required`, so a release PR cannot merge on placeholder notes (`scripts/release-notes.py` runs it locally) |
| `build.yml` → `smoke-host` | ubuntu | PR · push `recipe` | C++ patches compile; `node -e` runs; `test-mobile-fetch` passes on that build run `--jitless` (see below); `test-mobile-system-ca` finds a non-empty system trust store; the curated list and the full `parallel` suite pass on the host build. Gates `ci-required` and `publish` |
| `build.yml` → `build-*` / `combine-*` | ubuntu / macos | PR · push `recipe` | the cross-compile actually succeeds — the only check that compiles target code |
| `build.yml` → `smoke-{android,ios}` (+ the NAPI symbol assert in `combine-android`) | ubuntu+KVM / macos | PR · push `recipe` | **boot smoke**: the exact shipping artifact boots and runs JS; NAPI symbols in `.dynsym` |
| `build.yml` → `curated-tests-android` / `curated-tests-ios` | ubuntu+KVM / macos | PR · push `recipe` · releases | **curated device tests**: the curated subset + crc-native addon load on an x86_64 emulator and arm64 simulator |
| `full-device-suite.yml` (also `build.yml` → `full-suite-android` / `full-suite-ios` on releases and on PRs that bump `upstream-base.txt`) | ubuntu+KVM / macos | nightly 03:00 UTC · dispatch · releases · upstream-bump PRs | **full device suite**: the whole non-`.status`-skipped `test/parallel` + `test/sequential` suite on both platforms, 4 round-robin shards each (`test.py --run=n,4`). The curated gate covers what someone chose; this covers everything else, so a test upstream adds tomorrow is picked up without anyone noticing it exists. On a PR that moves the pinned tag it also gates `ci-required` (via `full-suite-gate`): an upgrade carries whatever tests upstream added, and an allow-list gate cannot see them |
| `build.yml` → `real-device-smoke-android` / `real-device-smoke-ios` | ubuntu / macos-15 + BrowserStack | releases (untagged version of record; required to publish) · dispatch | **real-device smoke**: boot + crc-native addon load on physical devices — Android arm64 (Pixel 9, 16 KB pages) via Espresso and iPhone via XCUITest. The iOS leg runs **once per flavor** (`ios_flavors`, both by default): a simulator is a macOS process and is not subject to the address-space limits a real iOS process is, so simulator-only coverage cannot tell you a flavor boots on hardware. Android is still full-only. Needs `BROWSERSTACK_USER`/`BROWSERSTACK_PW` secrets. |

Every job first **materializes** the source tree from the recipe branch
(`.github/actions/materialize` runs `scripts/prepare.sh` and verifies the
tree hash), then proceeds exactly as it would on a full checkout. On a release
(or a `release-dryrun:` rehearsal commit), one `build.yml` run carries the
whole gate chain — smokes, device suites, real devices, and publish —
connected by `needs:`; there is no cross-run lookup, label contract, or
manual step.

### Flavors, and what's required to merge

Every job that consumes a binary tests **both flavors** (`full` and `lite`),
with one deliberate exception: on `pull_request` the **iOS** legs build and
test `full` only. Hosted macOS concurrency is capped far below Linux, the full
chain wants eight concurrent macOS jobs, and what the lite iOS leg uniquely
catches — lite-specific configure/link breakage — is caught at compile time on
the merge run anyway. Android runs both flavors everywhere (ubuntu+KVM is
1×-billed and plentiful). Pushes and releases run both on both platforms.

`build.yml` exposes a single aggregate check, **`ci-required`**, which is what
branch protection should require — the matrix produces check names that change
whenever the matrix does, so a hand-maintained required list silently stops
enforcing. It covers the builds, the combines, the boot smokes and the
release-notes check.

**The curated device tests run on PRs but are deliberately not required.**
Emulator and simulator lifecycles (AVD boot, `simctl` races, adb disconnects)
are the flakiest part of this system, and a required check that flakes teaches
everyone to re-run or bypass — which costs more than the check is worth. Read
it; don't merge through a red one without knowing why it's red. They are
blocking on the release chain, where `publish` `needs:` them.

The real-device smoke stays release-only: GitHub Actions minutes are free for
this project, BrowserStack device minutes are not. Within that budget the iOS
leg still runs per flavor rather than for `full` alone — the flavor a consumer
ships is the one that has to be proven on hardware, and 24.19.0-1 shipped an
iOS `lite` build that aborted during `Isolate` init on every physical device
while every simulator leg stayed green.

### The curated gate and the full suite

Device testing is split in two, because one job cannot be both fast enough
for a PR and broad enough to be trusted:

- **Curated device tests** — `curated-tests-android` / `curated-tests-ios`,
  driven from `build.yml` on every PR and push. The curated allow-list
  (~200 tests), deterministic and a few minutes per platform. It answers
  "did this change break something we already care about".
- **The full device suite** — `full-device-suite.yml`. Everything
  `parallel.status` and `sequential.status` do not skip — a few thousand
  tests per platform, split four ways. It answers "what is true on a device
  that we have not looked at", which is the larger question: the curated gate
  covers about 6% of the runnable suite. `sequential`'s mobile skips are
  measured, not assumed — every non-structural skip covers a test that spawns
  a child process, and the tests the skips leave pass on both platforms.

The important property of the full suite is that it is **not an allow-list**.
A test upstream adds in the next bump runs the night after the bump lands,
with no curation step; excluding something requires a `.status` entry, which
is a decision with a name and a reason attached. An allow-list drifts
silently — a test nobody added is indistinguishable from a test somebody
excluded.

The full suite runs two ways: **nightly** (03:00 UTC, against the head
commit's Build artifacts; skipped when that commit already has a green run,
since retesting identical bytes buys nothing) and as a **release gate** —
`build.yml` calls it as the `full-suite-android` and `full-suite-ios` jobs on
release runs (one call per platform, so each platform's shards start as soon
as its own artifacts pass the boot smoke instead of waiting for the slower
platform's build), and `publish` `needs:` both, so a release
cannot ship with a full-suite failure. It is release-only rather than
per-PR because it costs about eight device-hours per run, which the PR loop
cannot absorb; the nightly covers drift the rest of the time. Each shard
writes a summary (counts, plus the failing names, with hangs and crashes
counted separately — they mean different things) and uploads its log.

### The curated subset

`tools/mobile-test/curated-device-tests.txt` is the allow-list (~200
single-process `test/parallel` cases) shared by both device workflows, so a
regression fails the same named test on both platforms. It is hand-maintained:
add and remove entries directly, following [the expansion
procedure](#expanding-the-curated-list) below. The runner invocation is:

```sh
# Android emulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/curated-device-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 --arch android

# iOS simulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/curated-device-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 \
      --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

`-j 1` is required (the proxy relaunches the app once per test; parallel
relaunches on one device cause spurious timeouts). `--timeout=300` is larger
than the proxy's own ~120 s verdict poll so the proxy is the authoritative
deadline. Tests that can't run on mobile (`child_process`, `cluster`, `fork`,
signals, OpenSSL-CLI, …) are skipped via the upstream
`[$system==android]` / `[$system==ios]` sections of `test/*/*.status` — kept out
of the test bodies.

### What the subset does not cover

The allow-list is weighted towards the patch series' blast radius — `net`,
`tls`, `timers`, `process`, `fs`, `dns`, `dgram`, `crypto`, `worker` and `http`
are its ten largest modules — so what it misses is not a module the fork can
break, but sheer breadth: roughly 6% of the runnable suite.

Run `tools/mobile-test/coverage-manifest.py` for the current numbers. It
separates the two reasons a test is absent from a device run, which a green run
cannot: a `.status` skip is a recorded decision; everything else is a test
nobody has tried on a PR run. That gap, not the skip list, is where the
missing PR-time coverage lives, and the full device suite is what covers it.
`smoke-host` prints the table on every run.

Suites other than `parallel` and `sequential` (`message`, `es-module`,
`pummel`, …) never run on a device; they are out of scope for the device
gates.

### Expanding the curated list

The list grows by measurement, not by guessing: run candidates on both
platforms, keep what passes on both, and record a *reason* for anything that
does not. Everything below runs from a materialized tree with the app already
prepared (see "Running tests locally").

**1. Pick candidates.** Anything not already in the list and not
`.status`-skipped is fair game; prefer whole modules over scattered files, and
prefer modules the patch series can plausibly break (`fs`, `net`, `stream`,
`crypto`, `worker`, `dgram`, `timers`, `vm`, `dns`) over more `buffer` tests.

```sh
ls test/parallel/test-fs-*.js | sed 's|test/|| ; s|\.js$||' > /tmp/candidates.txt
```

**2. Run them on both platforms**, one at a time, keeping the per-test verdict:

```sh
xargs ./tools/test.py -j 1 --flaky-tests=dontcare --timeout=300 \
  --arch android < /tmp/candidates.txt
xargs ./tools/test.py -j 1 --flaky-tests=dontcare --timeout=300 \
  --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh < /tmp/candidates.txt
```

`--flaky-tests=dontcare` (rather than `skip`) is deliberate here: during a
harvest you want to see the flaky ones, not hide them.

**3. Run the failures three times before believing them.** Emulator and
simulator timing is the dominant source of noise, and a test that fails once in
three is a `PASS, FLAKY` entry, not a skip.

**4. Triage every failure into exactly one bucket**, and act on it:

| Bucket | What it looks like | What to do |
|---|---|---|
| platform limitation | needs a child process, a unix socket on iOS, `HOME`, a signal, a TTY | add to the `[$system==…]` section of the `.status` file **with a comment saying why** |
| flake | passes in isolation, fails in a batch; timing-sensitive | `PASS, FLAKY` in the `.status` file |
| harness limitation | no verdict; passes when run by hand | fix the harness — don't skip the test |
| real bug | fails the same way every time, for a reason in the diff | fix the patch |

Only the first two produce a `.status` edit, and both carry a reason. An
uncommented skip is indistinguishable from an oversight a year later.

**5. Add the survivors** to `tools/mobile-test/curated-device-tests.txt` and
re-run the whole list once on both platforms: a test can pass alone and fail
in company (the proxy relaunches the app per test, so device load is a real
variable).

Because these are all edits to files the fork owns (`.status` files belong to
the test-adaptations patch, the list lives in `mobile-src/`), they go back through
`scripts/regenerate-patches.py` like any other change, and `expected-tree.txt`
moves with them.

### The fetch / WebAssembly gate

`test/parallel/test-mobile-fetch` runs a `fetch()` against an in-process HTTP
server. That exercises undici's WebAssembly build of llhttp,
which on iOS runs on the bundled polywasm polyfill because a jitless V8 has no
WebAssembly of its own ([FAQ](./FAQ.md#does-fetch-work-what-about-webassembly)).

It also runs on **every PR and push**, without a device: `build.yml`'s `smoke-host` job runs
it on the host build with `--jitless`, which makes V8 drop its WebAssembly
exactly as the iOS build does — so a regression in the polyfill or in its
install path fails in ~10 minutes, at the PR boundary.

```sh
NODEJS_MOBILE_EXPECT_WASM_IMPL=polyfill ./out/Release/node --jitless \
  test/parallel/test-mobile-fetch.js                              # host, polyfill path
NODEJS_MOBILE_EXPECT_WASM_IMPL=engine ./out/Release/node \
  test/parallel/test-mobile-fetch.js                              # host, V8's own wasm
```

The test reports which implementation it ran on, and asserts it when
`NODEJS_MOBILE_EXPECT_WASM_IMPL` is set (`polyfill` | `engine`) -- so the
jitless step can't silently degrade into testing native wasm if a future V8
keeps WebAssembly under `--jitless`. The device runs leave it unset.

A third step runs upstream's `test-freeze-intrinsics` under the same jitless
engine:

```sh
./out/Release/node --jitless --frozen-intrinsics \
  test/parallel/test-freeze-intrinsics.js
```

`--frozen-intrinsics` is the one code path that reaches into the polyfill's
shape rather than just calling it: `internal/freeze_intrinsics.js` reads seven
`WebAssembly.*.prototype`s the moment the global exists, so a member the
polyfill doesn't implement doesn't fail a `fetch()` — it stops the runtime from
booting at all. This step makes such a gap fail here instead of in an
embedder's app.

### What covers which patch

Most of the curated list is upstream tests that happen to pass on mobile.
Those catch a patch that breaks *node*, which is most of the risk — but not a
patch that stops doing its own job. Several patches only change behaviour on
Android or on iOS, so no upstream test ever observes them, and a revert would
sail through every job. The fork-only tests below close that gap: one per
patch, each running on the host build (where it proves the assertion is
well-formed, and catches an outright break) and on both devices (where the
patched behaviour is the behaviour).

Patches are named as in [the series table](./PATCHES.md#the-series).

| Test | Patch | What a regression looks like |
|---|---|---|
| `test-mobile-credentials` | node.cc guards, credentials | on Android, `process.getuid()` disappears (guards gone) or `process.setuid()` reaches the native setter instead of being inert (credentials gone). Everywhere, `process.initgroups()` stops resolving group names — the only JS path into the bionic `getgrnam()` lookup the credentials patch adds |
| `test-mobile-worker-env-clone` | env clone | a default-`env` worker comes up with a missing or partial environment; on Android, with one unclonable variable present, it does not come up at all |
| `test-mobile-system-ca` | crypto trust | `tls.getCACertificates('system')` throws, hands back expired or duplicated certificates, or comes back empty where the platform has a readable store |
| `test-mobile-node-path` | credentials (`SafeGetenv()`) | `NODE_PATH`, as the embedder set it, stops reaching module resolution |
| `test-mobile-fetch` | WebAssembly polyfill | see [the fetch / WebAssembly gate](#the-fetch--webassembly-gate) |
| `test-mobile-unix-socket` | none — a platform property | a unix socket bound from its own directory with a short relative path stops accepting connections. See [unix domain sockets](#unix-domain-sockets) |

Three limits are structural, and worth stating rather than papering over:

- **The env-clone patch has no deterministic trigger from JS.**
  `KVStore::Clone()` only fails when a name enumerates and then doesn't
  resolve, which is a property of the real process environment (bionic strips
  `LD_PRELOAD` and friends out of a starting app) and can't be staged from a
  test. The test asserts the post-condition instead — the worker starts, and
  its environment is the parent's — which is what a lost patch breaks on
  Android.
- **The `SafeGetenv()` change is invisible on a host build.** `SafeGetenv()`
  and `process.env` agree unless the process looks privileged, so the host run
  passes either way. The Android leg is the gate: a zygote-forked app process
  inherits an auxiliary vector that makes upstream's privilege heuristic
  decline every variable read through `SafeGetenv()`, permanently — see
  [EMBEDDING.md](./EMBEDDING.md#two-read-paths-and-why-it-matters) for the
  mechanism and the affected variables, and the credentials patch body for why
  the fix is gated on `NODE_MOBILE` rather than on the OS.
- **The crypto-trust patch's store can legitimately be empty on iOS**, where an app
  is sandboxed away from the system keychain — that's a platform fact, not a
  regression. So the test asserts the reader's invariants unconditionally and
  demands a non-empty result only when the caller says the platform has one:

  ```sh
  NODEJS_MOBILE_EXPECT_SYSTEM_CA=nonempty \
    ./out/Release/node test/parallel/test-mobile-system-ca.js
  ```

  `smoke-host` sets it, since a Linux build reading `/etc/ssl` has no excuse
  for an empty store. The device runs leave it unset, the same arrangement
  `NODEJS_MOBILE_EXPECT_WASM_IMPL` uses above.

### The working directory

A desktop `tools/test.py` run starts node with the working directory at the tree
root, and a good part of the suite quietly depends on it: `test-dotenv` passes
`--env-file test/fixtures/dotenv/valid.env`, `test-fs-cp-async-file-url` opens
`./test/fixtures/copy/kitchen-sink`, and `common.PIPE` builds a socket path
relative to `process.cwd()` on purpose, to keep it short.

An embedded node inherits the host app's cwd, which is `/`, where every one of
those would resolve against the filesystem root — so the app `chdir()`s to the
on-device tree root before starting node, the same starting point a desktop run
has. That is a harness behaviour only; it says nothing about what cwd a real
embedder should use, and libnode is untouched.

Worth knowing for embedders regardless: **cwd is `/` in an app process** unless
you set it. Anything resolving a relative path — including a unix socket path —
should not assume otherwise.

### Unix domain sockets

UDS works in both sandboxes. What differs is how long the socket path may be:
Darwin caps `sockaddr_un.sun_path` at **104 bytes** (Linux allows 108), and the
kernel stores the path exactly as passed.

An iOS app's data container is long before you add a filename — about 81 bytes
on a device, about 171 on the simulator — so an absolute path inside it does not
fit, and `bind()` fails with **`EINVAL`**. That is a path-length limit, not a
missing feature: the same socket completes a round-trip when bound from inside
its own directory with a short relative name.

Upstream's `common.PIPE` builds a relative path for exactly this reason — but
relative to `process.cwd()`, so it only stays short because the app `chdir()`s
to the on-device tree root at launch (see
[the working directory](#the-working-directory)). With that in place all 18
upstream UDS tests run and pass on the simulator; `test-mobile-unix-socket`
gates the behaviour directly, independent of upstream's helper.

On Android the container path is short (~50 bytes) and the limit never bites:
the upstream UDS tests pass there. Abstract-namespace sockets (`@`-prefixed) are
Linux-only and have no iOS equivalent.

**For embedders:** `chdir()` to the socket's directory and bind a relative path.
That is portable across both platforms, device and simulator alike. An absolute
path works on Android and on an iOS *device* if the whole string stays under 104
bytes, and cannot work on the iOS simulator. Note `os.tmpdir()` on iOS returns a
path inside the container, so it carries the full prefix.

### fs.watch

`fs.watch()` works on both platforms, but on **iOS it cannot tell you which file
changed** for a non-recursive watch. libuv compiles FSEvents out on iOS —
*"iOS (currently) doesn't provide the FSEvents-API (nor CoreServices)"*,
`deps/uv/src/unix/fsevents.c` — and falls back to kqueue, which watches a
directory file descriptor and reports only that the directory changed. The
`filename` argument comes back as the watched directory's own name.

The visible consequence is that the **`ignore` option filters out everything**,
even a predicate that never matches, because node applies it to that filename.
Recursive watching is unaffected: node implements that in JS and does report
proper relative paths.

This is upstream libuv behaviour on the platform, not something this fork can
fix — a stock macOS build of the same node version behaves identically. The
affected tests are skipped for iOS with that reason recorded.

**For embedders:** don't rely on `filename` from a non-recursive `fs.watch` on
iOS, and don't use the `ignore` option there.

### Tests under `--permission`

A test that runs with `--permission` but without `--allow-fs-write` cannot be
scored when it calls `process.exit()`: the harness writes its verdict to a file
from a `process.on('exit')` hook, and the permission model — correctly — denies
that write, so no verdict lands and the run reports FAIL whatever the test did.
This is not fixable from inside the sandbox doing the denying. The 22 affected
cases are skipped, with that reason recorded next to them in `parallel.status`.

### The NAPI addon gate

After the curated subset, each device workflow builds the **crc-native** N-API
addon (`tools/mobile-test/addon/`) against that build's library and loads it in
the testnode app — proving a real `.node` addon `dlopen`s and runs (the
"blocker B-1" check the symbol-grep smoke only approximates).

## Running tests locally

Every command in this section runs from a materialized source tree — the
`out/` that `scripts/prepare.sh` produces (see [BUILDING.md](./BUILDING.md)),
not from this branch.

`tools/test.py` and the prepare scripts run on the host; the device/emulator
runs the app. A specific device/emulator can be targeted with `DEVICE_ID=<id>`
(`adb devices` / `xcrun devicectl list devices` / `xcrun simctl list` to find it).

> **WASI symlink side-effect.** The prepare scripts delete the dangling symlinks
> under `test/fixtures/wasi/subdir/` (Android asset packaging and iOS app
> install reject them). Restore them before committing:
> `git checkout -- test/fixtures/wasi/subdir/`.

### Android emulator (or device)

Requires a **Linux** host (Android can't cross-build on macOS — see
[BUILDING.md](./BUILDING.md)), NDK r27d, JDK 17, and `adb`.

```sh
./tools/android_build.sh "$ANDROID_NDK_HOME" 24 x86_64   # build libnode (x86_64 for an emulator)
./tools/mobile-test/android/prepare-android-test.sh      # build+install the app, copy test assets, drop the proxy
# then run the curated subset (command above), or a single test:
echo test/parallel/test-buffer-alloc.js | xargs ./tools/test.py -j 1 --arch android
```

### iOS simulator

Requires macOS + Xcode.

```sh
./tools/ios_framework_prepare.sh arm64-simulator              # build the simulator framework
./tools/mobile-test/ios/prepare-ios-sim-tests.sh              # build+install the app on a booted simulator, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

### iOS physical device

Requires macOS + Xcode 15+, an arm64 device on iOS 17 or newer with Developer
Mode enabled, and an Apple Development certificate whose account is signed
into Xcode. Everything device-facing runs through `xcrun devicectl`
(CoreDevice): `ios-deploy` is no longer used — its lldb launch phase cannot
work on iOS 17+, where the personalized developer disk image replaced the
`DeveloperDiskImage.dmg` it looks for. (For an iOS 16-or-older device, use the
old ios-deploy scripts from git history.)

```sh
./tools/ios_framework_prepare.sh arm64                        # build the device framework
NODE_IOS_DEV_TEAM=<your team id> \
  ./tools/mobile-test/ios/prepare-ios-tests.sh                # build+sign+install, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-proxy.sh
```

`NODE_IOS_DEV_TEAM` makes xcodebuild sign with your team (automatic signing +
`-allowProvisioningUpdates`); without it the project's own — empty — signing
settings apply. `DEVICE_ID` takes a CoreDevice identifier or name (`xcrun
devicectl list devices`, *not* the classic UDID) and is auto-selected when
exactly one device is connected. If the default bundle id is taken on your
account, export `NODE_IOS_BUNDLE_ID` for both scripts.

The device proxy scores from the same verdict file as the other two: it passes
a per-launch token and pulls `Documents/result-<token>.txt` back out of the
app's data container with `devicectl device copy from`, rather than trusting an
exit code. This flow is local-only; no CI job runs it (real-device coverage
goes through BrowserStack).

### Running the addon gate locally

```sh
# Android (after prepare-android-test.sh):
./tools/mobile-test/addon/build-android-addon.sh "$ANDROID_NDK_HOME" x86_64 out_android/x86_64 out_android/libnode/include/node ./crcnative.node
./tools/mobile-test/addon/run-android-addon.sh ./crcnative.node
# iOS simulator (after prepare-ios-sim-tests.sh): see tools/mobile-test/addon/build-ios-addon.sh + run-ios-addon.sh
```
