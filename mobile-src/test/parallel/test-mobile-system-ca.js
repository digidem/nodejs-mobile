'use strict';

// Mobile gate for the Apple system trust store reader (patch 0010; see
// docs/PATCHES.md on the recipe branch).
//
// src/crypto/crypto_context.cc reads the platform trust store so that
// --use-system-ca (and tls.getCACertificates('system'), the only public entry
// point into it) can see the certificates the OS trusts. Its Apple half is
// written for macOS: SecTrustSettingsCopyTrustSettings and the
// kSecTrustSettings* keys are macOS-only API, and an iOS build does not even
// link against them. The fork wraps those spans in `#if TARGET_OS_OSX` and,
// on iOS, falls back to asking the system about each certificate directly --
// IsCertificateTrustValid(), i.e. SecTrustEvaluateWithError().
//
// A platform guard like that is exactly the kind of patch an upstream
// restructure breaks quietly: the compiler only proves the `#if` encloses
// *some* valid span, not the right one (docs/UPGRADING.md on the recipe
// branch). Without a runtime caller the whole reader can stop returning
// anything and every job stays green. So: call it, and assert the things the
// reader promises its caller.
//
// Two of those promises -- no expired certificates, no duplicates -- are
// specific to the Apple reader; the OpenSSL reader used on Android and on the
// Linux host neither filters nor de-duplicates, so they are asserted only
// where they hold.
//
// The store can legitimately be empty: an app on iOS is sandboxed away from
// the system keychain, so an iOS build may find no enumerable anchors at all,
// which is a platform fact and not a regression. Where a non-empty store *is*
// expected (the Linux host build reading /etc/ssl), the caller says so with
// NODEJS_MOBILE_EXPECT_SYSTEM_CA=nonempty rather than the test guessing --
// the same arrangement test-mobile-fetch uses for the WebAssembly backend.

const common = require('../common');
const assert = require('assert');
const tls = require('tls');
const { X509Certificate } = require('crypto');

const PEM_HEADER = '-----BEGIN CERTIFICATE-----';
const isApple = common.isIOS || common.isMacOS;

function assertPemList(certs, what) {
  assert.ok(Array.isArray(certs), `${what} is not an array`);
  assert.ok(Object.isFrozen(certs), `${what} is not frozen`);
  for (const pem of certs) {
    assert.strictEqual(typeof pem, 'string', `${what} holds a non-string`);
    assert.ok(pem.startsWith(PEM_HEADER), `${what} holds a non-PEM entry`);
  }
}

// The bundled roots are compiled in, so they are the control: if these are
// wrong the problem is not the trust store reader.
const bundled = tls.getCACertificates('bundled');
assertPemList(bundled, 'bundled');
assert.ok(bundled.length > 100, `bundled roots: ${bundled.length}`);

// The patched reader. It must not throw, must not crash the process, and must
// not hand back anything that isn't a certificate.
const system = tls.getCACertificates('system');
assertPemList(system, 'system');
console.log(`system trust store: ${system.length} certificate(s)`);

const fingerprints = new Set();
for (const pem of system) {
  const cert = new X509Certificate(pem);
  assert.ok(cert.subject, `system certificate with no subject:\n${pem}`);
  if (isApple) {
    // ReadMacOSKeychainCertificates() drops expired certificates and
    // de-duplicates what it keeps.
    assert.ok(cert.validToDate > new Date(),
              `expired system certificate: ${cert.subject}`);
    assert.ok(!fingerprints.has(cert.fingerprint256),
              `duplicate system certificate: ${cert.subject}`);
    fingerprints.add(cert.fingerprint256);
  }
}

// The read happens once behind a function-local static and is cached in JS on
// top of that, so a second call is the same frozen array -- not a second walk
// of the keychain that could answer differently.
assert.strictEqual(tls.getCACertificates('system'), system);

// 'default' is the bundled set, plus the system set when the binary was
// started with --use-system-ca / NODE_USE_SYSTEM_CA. Whatever this run did,
// it cannot come out smaller than the bundled set.
const def = tls.getCACertificates('default');
assertPemList(def, 'default');
assert.ok(def.length >= bundled.length,
          `default (${def.length}) < bundled (${bundled.length})`);

// Opt-in assertion for callers that know this platform has a readable store.
const expectation = process.env.NODEJS_MOBILE_EXPECT_SYSTEM_CA;
if (expectation) {
  assert.strictEqual(expectation, 'nonempty',
                     `unknown NODEJS_MOBILE_EXPECT_SYSTEM_CA: ${expectation}`);
  assert.ok(system.length > 0, 'system trust store came back empty');
}
