# polywasm (vendored)

A pure-JavaScript implementation of the `WebAssembly` API, shipped inside the
mobile binary and installed as `globalThis.WebAssembly` by
`lib/internal/process/pre_execution.js` when — and only when — the engine has
none of its own.

That is the case on iOS: Apple forbids runtime code generation, so the iOS
build runs V8 jitless (`tools/ios_framework_prepare.sh` passes
`--v8-options=--jitless`, and `--v8-lite-mode` drops the wasm engine from the
binary outright), and a jitless V8 exposes no `WebAssembly` global at all.
Without a stand-in, `fetch()` is dead — undici parses HTTP with a WebAssembly
build of llhttp — and so is everything undici backs (`Response`, `Request`,
`Headers`, `FormData`, `WebSocket`, `EventSource`). polywasm compiles each wasm
function to JavaScript with `new Function()`, which jitless V8 allows: the
restriction is on machine code, not on parsing source.

See [FAQ.md](https://github.com/nodejs-mobile/nodejs-mobile/blob/patches/docs/FAQ.md#does-fetch-work-what-about-webassembly)
for the user-facing behaviour and the polyfill's limits (no SIMD,
threads/atomics, exception handling or GC; much slower than a real engine).

## Provenance

| | |
|---|---|
| Package | [`polywasm`](https://www.npmjs.com/package/polywasm) `0.2.0` ([source](https://github.com/evanw/polywasm)) |
| License | MIT — [LICENSE.md](./LICENSE.md), also recorded in the tree's root `LICENSE` |
| Tarball | `https://registry.npmjs.org/polywasm/-/polywasm-0.2.0.tgz` |
| Tarball `sha256` | `810a536198bf07671fb9ff95f26efbed7dd4e07907e8434c1048275ec0abf7b3` |
| `package/index.js` `sha256` | `b52d3e02376f2da1317e7652c584ea6c7cb6dc09cc8238bf7f216bc9ff5021c0` |

`polywasm.js` is that `index.js`, byte for byte, with exactly one hunk changed:
its ESM export becomes a CommonJS one, because `js2c` wraps every builtin as
CommonJS and `export { … }` is a syntax error inside that wrapper.

```diff
-export {
-  wasmAPI as WebAssembly
-};
+module.exports = { WebAssembly: wasmAPI };
```

Nothing else is edited — no header, no reformatting — so the vendored copy stays
diffable against what npm serves.

## Verifying

```sh
tools/dep_updaters/update-polywasm.sh          # asserts the vendored copy reproduces npm
```

With no argument the script re-downloads the recorded version, checks both
hashes, regenerates the file and asserts it is byte-identical to the one in
tree. By hand, if you'd rather not trust the script:

```sh
npm pack polywasm@0.2.0
diff <(tar xzOf polywasm-0.2.0.tgz package/index.js) deps/polywasm/polywasm.js
```

One expected hunk, the export above.

This is deliberately **not** a CI step: the build and `scripts/prepare.sh`
reach only GitHub, and making either depend on the npm registry would put
registry availability in the path of a reproducible build. The tree hash in
`expected-tree.txt` is what CI checks, and it covers these bytes.

## Updating

```sh
tools/dep_updaters/update-polywasm.sh 0.3.0
```

The script downloads that version, applies the export rewrite (failing loudly
if upstream's export shape changed), and writes `polywasm.js`. Then, from the
repository root of the recipe:

1. update the version and both hashes in the table above (the script prints them),
2. refresh `LICENSE.md` here and the `polywasm` block in the tree's `LICENSE`
   if upstream's copyright line changed,
3. `scripts/regenerate-patches.py out` and commit the new `expected-tree.txt`,
4. keep the file ASCII-only — `js2c` embeds a non-ASCII builtin as UTF-16,
   doubling ~100 KB of source in every binary for nothing.
