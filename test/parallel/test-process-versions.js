'use strict';
const common = require('../common');
const assert = require('assert');

// Import of pure js (non-shared) deps for comparison.
//
// nodejs-mobile: the test assets copied into the app sandbox carry no
// root-level "deps" folder, so on-device these files cannot be read at all --
// the version cross-checks they feed are deferred to the bottom of this file
// and skipped there. They are not replaced by hard-coded version strings: a
// literal here goes stale at the next upstream bump and then fails on every
// platform instead of only on the one that can't do the check.
const canReadDeps = !common.isAndroid && !common.isIOS;

const expected_keys = [
  'ares',
  'brotli',
  'zstd',
  'modules',
  'uv',
  'v8',
  'zlib',
  'nghttp2',
  'nghttp3',
  'ngtcp2',
  'napi',
  'llhttp',
  'uvwasi',
  'acorn',
  'simdjson',
  'simdutf',
  'ada',
  'nbytes',
  'merve',
];

if (common.isAndroid || common.isIOS) {
  expected_keys.push('mobile');
}

const hasUndici = process.config.variables.node_builtin_shareable_builtins.includes('deps/undici/undici.js');
const hasAmaro = process.config.variables.node_builtin_shareable_builtins.includes('deps/amaro/dist/index.js');

if (process.config.variables.node_use_amaro) {
  if (hasAmaro) {
    expected_keys.push('amaro');
  }
}
if (hasUndici) {
  expected_keys.push('undici');
}

if (common.hasCrypto) {
  expected_keys.push('openssl');
  expected_keys.push('ncrypto');
}

if (common.hasIntl) {
  expected_keys.push('icu');
  expected_keys.push('cldr');
  expected_keys.push('tz');
  expected_keys.push('unicode');
}

if (common.hasSQLite) {
  expected_keys.push('sqlite');
}

expected_keys.sort();
expected_keys.unshift('node');

const actual_keys = Object.keys(process.versions);

assert.deepStrictEqual(actual_keys, expected_keys);

const commonTemplate = /^\d+\.\d+\.\d+(?:-.*)?$/;

assert.match(process.versions.acorn, commonTemplate);
assert.match(process.versions.ares, commonTemplate);
assert.match(process.versions.brotli, commonTemplate);
assert.match(process.versions.llhttp, commonTemplate);
assert.match(process.versions.merve, commonTemplate);
assert.match(process.versions.node, commonTemplate);
assert.match(process.versions.uv, commonTemplate);
assert.match(process.versions.nbytes, commonTemplate);
assert.match(process.versions.zlib, /^\d+(?:\.\d+){1,3}(?:-.*)?$/);
assert.match(process.versions.zstd, commonTemplate);

if (hasUndici) {
  assert.match(process.versions.undici, commonTemplate);
}

assert.match(
  process.versions.v8,
  /^\d+\.\d+\.\d+(?:\.\d+)?-node\.\d+(?: \(candidate\))?$/
);
assert.match(process.versions.modules, /^\d+$/);

if (common.hasCrypto) {
  const { hasOpenSSL3 } = require('../common/crypto');
  assert.match(process.versions.ncrypto, commonTemplate);
  if (process.config.variables.node_shared_openssl) {
    assert.ok(process.versions.openssl);
  } else {
    const versionRegex = hasOpenSSL3 ?
      // The following also matches a development version of OpenSSL 3.x which
      // can be in the format '3.0.0-alpha4-dev'. This can be handy when
      // building and linking against the main development branch of OpenSSL.
      /^\d+\.\d+\.\d+(?:[-+][a-z0-9]+)*$/ :
      /^\d+\.\d+\.\d+[a-z]?(\+quic)?(-fips)?$/;
    assert.match(process.versions.openssl, versionRegex);
  }
}

for (let i = 0; i < expected_keys.length; i++) {
  const key = expected_keys[i];
  const descriptor = Object.getOwnPropertyDescriptor(process.versions, key);
  assert.strictEqual(descriptor.writable, false);
}

assert.strictEqual(process.config.variables.napi_build_version,
                   process.versions.napi);

// nodejs-mobile: `canReadDeps` -- see the top of this file. Where deps/ is out
// of reach the shape of both versions is still asserted above, against
// `commonTemplate`; only the value cross-check is skipped.
if (hasUndici && canReadDeps) {
  const undici = require('../../deps/undici/src/package.json');
  const expectedUndiciVersion = undici.version;
  assert.strictEqual(process.versions.undici, expectedUndiciVersion);
}

if (canReadDeps) {
  const acorn = require('../../deps/acorn/acorn/package.json');
  const expectedAcornVersion = acorn.version;
  assert.strictEqual(process.versions.acorn, expectedAcornVersion);
}
