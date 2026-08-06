# Node.js for Mobile Apps

Full Node.js, built as an embeddable native library for **Android** and
**iOS** — the runtime your app links against to run a real Node.js process
in-app, with npm modules and N-API native addons.

| Platform | Artifact | ABIs / slices |
|---|---|---|
| Android | `libnode.so` + headers | `arm64-v8a`, `armeabi-v7a`, `x86_64` (16 KB page size) |
| iOS | `NodeMobile.xcframework` | `arm64` device, `arm64` simulator |

Current line: **Node.js 24** (`v24.18.0`). `process.version` reports the
upstream version unchanged, so version-parsing tools keep working; the
mobile build is identified by `process.versions.mobile` (e.g. `"24.18.0-0"`).

## Get it

Download the zips from [Releases](../../releases) — four per release:

```
nodejs-mobile-android-X.Y.Z-R.zip        nodejs-mobile-ios-X.Y.Z-R.zip
nodejs-mobile-android-lite-X.Y.Z-R.zip   nodejs-mobile-ios-lite-X.Y.Z-R.zip
```

**`full`** is the general-purpose binary — pick it unless size is critical.
**`lite`** is ~30% smaller on iOS but drops ICU, the inspector,
`node:sqlite`, and TypeScript type-stripping (see
[BUILDING.md](docs/BUILDING.md#the-lite-variant) for the
full list and the caveats — the `Intl` one needs checking against your
dependency tree).

To embed it in an app, most people use a plugin rather than the raw library:
[nodejs-mobile-react-native](https://github.com/nodejs-mobile/nodejs-mobile-react-native)
· [nodejs-mobile-cordova](https://github.com/nodejs-mobile/nodejs-mobile-cordova).
See the [FAQ](docs/FAQ.md) for what mobile platforms do and
don't allow (child processes, writable paths, native modules, `Intl`).

## How this repository works

This repo does **not** contain a copy of Node.js. It contains the *recipe*
for building one — about 1.5 MB instead of a 1 GB fork:

| | |
|---|---|
| `upstream-base.txt` | the pinned upstream release tag (`v24.18.0`) |
| `patches/` | per-concern patches to upstream files, plus `series` (apply order) and `files.map` (which patch owns which file) |
| `mobile-src/` | files that have no upstream counterpart — build scripts, the iOS framework project, test apps and harness |
| `expected-tree.txt` | the git tree hash the reconstruction must produce |
| `scripts/` | `prepare.sh` (recipe → source tree) and `regenerate-patches.py` (source tree → recipe) |

`scripts/prepare.sh` clones upstream at the pinned tag, applies the patch
series, overlays `mobile-src/`, and verifies the result hashes to
`expected-tree.txt` — so what CI builds, what a release tag contains, and
what was reviewed here are provably the same bytes.

```sh
scripts/prepare.sh          # → ./out, a complete, verified Node.js source tree
cd out && ./tools/android_build.sh "$ANDROID_NDK_HOME" 24 arm64
```

Because the mobile diff is a set of small, labelled patches, "what does this
project actually change in Node.js?" is answerable by reading `patches/`, and
an upstream upgrade is a handful of small conflicts rather than a re-import.

## Make a change

```sh
scripts/prepare.sh                       # one-time: get ./out
cd out && $EDITOR src/node.cc && make -j node   # edit + build + test
cd .. && scripts/regenerate-patches.py out      # fold changes back into patches/ + mobile-src/
```

Then commit the regenerated files with the `expected-tree.txt` hash the
script prints, and open a PR. Full walkthrough and review process:
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## Documentation

All of the project's documentation lives in [`docs/`](docs/) on this branch —
including the docs about the source tree, which is generated and therefore
carries no docs of its own.

**Working on this repo**

- [CONTRIBUTING.md](docs/CONTRIBUTING.md) — dev loop, patch rules, review process, DCO
- [PATCHES.md](docs/PATCHES.md) — the patches model in depth: what the files mean, how the integrity check works, why it's built this way
- [UPGRADING.md](docs/UPGRADING.md) — moving to a newer upstream Node.js release
- [RELEASING.md](docs/RELEASING.md) — cutting and publishing a release

**Building and using the source**

- [BUILDING.md](docs/BUILDING.md) — build Android and iOS by hand, host requirements, build flavors
- [TESTING.md](docs/TESTING.md) — how tests pass on device, what CI runs, running tests locally
- [EMBEDDING.md](docs/EMBEDDING.md) — the environment node inherits: what to set before starting it, and where to write
- [FAQ.md](docs/FAQ.md) — what is and isn't supported on mobile
- [CHANGELOG.md](docs/CHANGELOG.md) — release history

## Testing and releases

Every push reconstructs the tree, validates each patch individually, and
builds all platforms and both flavors. A release additionally runs the
curated Node.js test subset on an Android emulator and an iOS simulator, and
a real-device smoke on physical hardware (BrowserStack: Android arm64 with
16 KB pages, and an iPhone) that boots the shipped binary and loads a real
N-API addon. Publishing is gated on all of it — see
[TESTING.md](docs/TESTING.md) and
[docs/RELEASING.md](docs/RELEASING.md).

## Project goals and license

1. Provide the fixes necessary to run Node.js on mobile operating systems.
2. Investigate what Node.js needs to be a useful mobile app development tool.
3. Diverge as little as possible from `nodejs/node` while doing (1) and (2).

Node.js is available under the MIT license; see `LICENSE` in a materialized
tree (or [upstream](https://github.com/nodejs/node/blob/main/LICENSE)). The
mobile patches and tooling in this repo are offered under the same terms.
