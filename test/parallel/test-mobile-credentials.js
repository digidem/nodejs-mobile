'use strict';

// Mobile gate for the POSIX credential surface (patches 0006 and 0007; see
// docs/PATCHES.md on the recipe branch).
//
// Upstream compiles the POSIX credential bindings out of Android entirely --
// node_internals.h leaves NODE_IMPLEMENTS_POSIX_CREDENTIALS undefined there,
// so process.getuid() and friends simply do not exist. This fork turns them
// back on for API level >= 21 (patch 0006) and then removes the pieces bionic
// or the Android sandbox cannot honour (patch 0007):
//
//   * getuid / geteuid / getgid / getegid / getgroups -- kept, must work.
//   * initgroups -- kept. Its group-name lookup runs through an Android-only
//     gid_by_name() built on getgrnam(), because bionic has no getgrnam_r().
//   * setuid / setgid / seteuid / setegid / setgroups -- dropped. Android does
//     not let a process change its credentials, so the native methods are not
//     registered at all.
//
// The JS wrappers in internal/bootstrap/switches/does_own_process_state.js are
// installed whenever the binding reports implementsPosixCredentials, i.e. also
// on Android, so there the setters still *exist* -- they just have no native
// method to reach. What matters, and what is asserted below, is that they
// never perform the operation.
//
// Nothing here needs privileges and nothing here has a side effect: every
// call is made with a credential name that cannot resolve, which fails in the
// lookup before the underlying syscall is ever attempted.

const common = require('../common');
const assert = require('assert');

// POSIX only. No target of this fork is Windows, but keep the file runnable.
if (common.isWindows) return;

const NO_SUCH_USER = 'nodejs-mobile-no-such-user';
const NO_SUCH_GROUP = 'nodejs-mobile-no-such-group';

// Patch 0006: the read-only half of the surface exists everywhere, including
// on Android where upstream has none of it.
for (const name of ['getuid', 'geteuid', 'getgid', 'getegid', 'getgroups']) {
  assert.strictEqual(typeof process[name], 'function', `process.${name}()`);
}
for (const name of ['getuid', 'geteuid', 'getgid', 'getegid']) {
  const id = process[name]();
  assert.strictEqual(typeof id, 'number', `process.${name}() -> ${id}`);
  assert.ok(Number.isInteger(id) && id >= 0, `process.${name}() -> ${id}`);
}
const groups = process.getgroups();
assert.ok(Array.isArray(groups), `process.getgroups() -> ${groups}`);
for (const gid of groups) {
  assert.strictEqual(typeof gid, 'number', `getgroups() member ${gid}`);
}

// Patch 0007 keeps initgroups(), and on Android its group-name argument is
// what reaches the bionic getgrnam() lookup -- the only JS path that does,
// since every other name-taking credential call is compiled out there.
//
// Upstream refuses initgroups() outright when the bundled libuv might be
// using io_uring (1.45 up to but excluding 1.49). Node 24 is past that
// window; skip rather than mis-assert if a future bump lands back in it.
const [uvMajor, uvMinor] = process.versions.uv.split('.').map(Number);
const uvMightUseIoUring = uvMajor === 1 && uvMinor >= 45 && uvMinor < 49;

assert.strictEqual(typeof process.initgroups, 'function');
if (!uvMightUseIoUring) {
  // A name that cannot resolve reaches gid_by_name() and comes back
  // gid_not_found, which the binding reports as result 2 and the JS wrapper
  // turns into ERR_UNKNOWN_CREDENTIAL. Passing the user as a *string* keeps
  // this to the group lookup: node only translates the user argument when it
  // is numeric, and hands a string straight to initgroups(3) -- which is also
  // why this never gets far enough to touch the process's real groups.
  assert.throws(() => process.initgroups(NO_SUCH_USER, NO_SUCH_GROUP), {
    code: 'ERR_UNKNOWN_CREDENTIAL',
    message: `Group identifier does not exist: ${NO_SUCH_GROUP}`,
  });
}

// Patch 0007's other half: the setters.
const SETTERS = ['setuid', 'seteuid', 'setgid', 'setegid', 'setgroups'];

function callSetter(name) {
  return name === 'setgroups' ?
    process[name]([NO_SUCH_GROUP]) :
    process[name](name.endsWith('uid') ? NO_SUCH_USER : NO_SUCH_GROUP);
}

for (const name of SETTERS) {
  if (common.isAndroid) {
    // The native method is not registered. Upstream's bootstrap installs the
    // JS wrapper unconditionally, so the property normally survives as an
    // inert function; either way it must not reach the credential lookup --
    // an ERR_UNKNOWN_CREDENTIAL here means the native setter came back.
    if (process[name] === undefined) continue;
    assert.throws(() => callSetter(name), (err) => {
      assert.notStrictEqual(err.code, 'ERR_UNKNOWN_CREDENTIAL',
                            `process.${name}() reached the native setter`);
      return true;
    }, `process.${name}()`);
  } else {
    assert.strictEqual(typeof process[name], 'function', `process.${name}()`);
    assert.throws(() => callSetter(name),
                  { code: 'ERR_UNKNOWN_CREDENTIAL' },
                  `process.${name}()`);
  }
}
