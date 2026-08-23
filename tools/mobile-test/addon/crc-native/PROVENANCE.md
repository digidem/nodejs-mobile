# Vendored N-API test fixture: crc-native

A minimal, genuine **N-API** (node-api) native addon for the mobile
native-addon release gate (see
[TESTING.md](https://github.com/nodejs-mobile/nodejs-mobile/blob/recipe/docs/TESTING.md)).
Loading and calling it on a device proves the shipped libnode exports the
`napi_*` symbol table and can `dlopen` + run a real addon end-to-end — the
"B-1" concern that the cheaper symbol-grep smoke (the "Assert NAPI symbols
are exported" step in build.yml on the recipe branch) only approximates.

## Provenance

- `binding.c`, `macros.h` — vendored **verbatim** from
  [holepunchto/crc-native](https://github.com/holepunchto/crc-native) @ `1.1.8`
  (Apache-2.0). This is the genuine N-API surface: `binding.c` registers via
  `napi_register_module_v1` (through `macros.h`'s `NAPI_INIT`/`NAPI_MODULE`) and
  calls `napi_get_buffer_info` / `napi_create_uint32` / `napi_throw_error`.
- `crc.h` — crc-native's one-function API (`crc_u32`), reproduced.
- `crc32.c` — **ours**: a self-contained IEEE CRC-32 that replaces crc-native's
  upstream `libcrc` dependency (which needs CMake + arch-specific CRC
  intrinsics). Identical output; `test-napi-addon.js` cross-checks the result
  against Node's built-in `zlib.crc32`, so a wrong implementation fails loudly.

crc-native is a real-world N-API module
([digidem/crc-native-nodejs-mobile](https://github.com/digidem/crc-native-nodejs-mobile)),
so this gate exercises a production addon rather than a toy.

The upstream `index.js`/`binding.js` load the addon via Bare's `require.addon`;
for Node we load the compiled addon directly with `process.dlopen` (see
`test-napi-addon.js`). The addon is **built from source** against each candidate
build's headers in CI (never a published prebuild) so the test binds to the
exact libnode under release.
