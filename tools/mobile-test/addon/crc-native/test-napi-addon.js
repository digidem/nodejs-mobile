'use strict';
// Loads a real N-API addon (crc-native) and exercises the napi_* surface the
// "B-1" concern is about: napi_register_module_v1 (dlopen + registration),
// napi_get_buffer_info + napi_create_uint32 (the JS<->native call), and
// napi_throw_error (the negative case). The addon's absolute on-device path is
// injected by the harness via NODE_MOBILE_ADDON so the proxy's ./test/ argv
// rewriter never touches it.
const assert = require('assert');
const zlib = require('zlib');

const addonPath = process.env.NODE_MOBILE_ADDON;
assert.ok(addonPath, 'NODE_MOBILE_ADDON env var (addon path) is required');

const mod = { exports: {} };
process.dlopen(mod, addonPath); // resolves napi_register_module_v1 against libnode
const crc32 = mod.exports.crc_u32_napi;
assert.strictEqual(typeof crc32, 'function', 'addon did not export crc_u32_napi');

const buf = Buffer.from('hello world');
const got = crc32(buf) >>> 0;
const ref = zlib.crc32(buf) >>> 0; // Node's built-in IEEE CRC-32 — no magic constant
assert.strictEqual(got, ref, `addon crc 0x${got.toString(16)} != zlib 0x${ref.toString(16)}`);
assert.strictEqual(got, 0x0d4a1185, `unexpected crc 0x${got.toString(16)}`);

// Negative path: a non-buffer arg must surface a native exception
// (napi_throw_error via macros.h's NAPI_STATUS_THROWS), proving error
// marshalling across the boundary, not just the happy path.
assert.throws(() => crc32(123), 'expected a thrown error for a non-buffer argument');

console.log(`NAPI_ADDON_OK crc=0x${got.toString(16)} ${process.platform} ${process.arch}`);
// No process.exit(): let the event loop drain so node_start returns 0 and the
// testnode harness writes a clean PASS verdict (see docs/TESTING.md on the
// recipe branch).
