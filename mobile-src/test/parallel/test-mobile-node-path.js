'use strict';

// Mobile gate for NODE_PATH (patch 0015; see docs/PATCHES.md on the recipe
// branch).
//
// Upstream's Module._initPaths() reads NODE_PATH through
// credentials::SafeGetenv(), which declines to answer at all when the process
// looks "secure" -- AT_SECURE set, or a real/effective uid or gid mismatch.
// That rule is written for a setuid `node` on a desktop. Here node is a
// library inside somebody else's app process: the embedder is the one that
// sets NODE_PATH, and the conditions SafeGetenv() keys off are properties of
// the host app, not of node. The patch reads process.env instead, on every
// platform, which is what Windows already did.
//
// The contract is therefore simply: NODE_PATH, as visible in process.env when
// Module._initPaths() runs, reaches module resolution. On a host build
// SafeGetenv() and process.env agree, so this passes with or without the
// patch there -- it is the Android and iOS device runs that fail
// when the patch goes away. Running it on the host is still worth it: it is
// what keeps the assertion honest as upstream moves _initPaths() around.

require('../common');
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const Module = require('module');
const tmpdir = require('../common/tmpdir');

tmpdir.refresh();

const dirA = tmpdir.resolve('node-path-a');
const dirB = tmpdir.resolve('node-path-b');
fs.mkdirSync(dirA, { recursive: true });
fs.mkdirSync(dirB, { recursive: true });
fs.writeFileSync(path.join(dirA, 'mobile-nodepath-a.js'),
                 'module.exports = "a";\n');
fs.writeFileSync(path.join(dirB, 'mobile-nodepath-b.js'),
                 'module.exports = "b";\n');

const originalNodePath = process.env.NODE_PATH;

process.on('exit', () => {
  if (originalNodePath === undefined) {
    delete process.env.NODE_PATH;
  } else {
    process.env.NODE_PATH = originalNodePath;
  }
  Module._initPaths();
});

// The built-in lookup paths are the ones that persist with NODE_PATH unset.
// They cannot be snapshotted from the launch state: on-device the harness
// itself sets NODE_PATH (the Android app points it at its files dir), so the
// launch-time globalPaths already contain NODE_PATH-derived entries that
// legitimately vanish when the test overwrites the variable — counting those
// as built-in is exactly how this test failed its first emulator run.
delete process.env.NODE_PATH;
Module._initPaths();
const builtinGlobalPaths = Module.globalPaths;

process.env.NODE_PATH = [dirA, dirB].join(path.delimiter);
Module._initPaths();

// Both entries land in the global lookup paths, ahead of the built-in ones
// and in the order NODE_PATH lists them.
assert.ok(Module.globalPaths.includes(dirA),
          `${dirA} missing from ${Module.globalPaths}`);
assert.ok(Module.globalPaths.includes(dirB),
          `${dirB} missing from ${Module.globalPaths}`);
assert.ok(Module.globalPaths.indexOf(dirA) < Module.globalPaths.indexOf(dirB),
          `NODE_PATH order lost in ${Module.globalPaths}`);
for (const dir of builtinGlobalPaths) {
  assert.ok(Module.globalPaths.includes(dir),
            `NODE_PATH displaced the built-in path ${dir}`);
}

// And they are what a bare specifier actually resolves against -- globalPaths
// is a copy kept for introspection, so asserting only on it would not prove
// the paths reached resolution.
assert.strictEqual(require('mobile-nodepath-a'), 'a');
assert.strictEqual(require('mobile-nodepath-b'), 'b');
assert.strictEqual(require.resolve('mobile-nodepath-a'),
                   path.join(dirA, 'mobile-nodepath-a.js'));

// Clearing it takes them away again: the value is read at _initPaths() time,
// not captured once at startup.
delete process.env.NODE_PATH;
Module._initPaths();
assert.ok(!Module.globalPaths.includes(dirA),
          `${dirA} survived NODE_PATH being cleared`);
assert.throws(() => require.resolve('mobile-nodepath-b'),
              { code: 'MODULE_NOT_FOUND' });

// Setting it again brings resolution back, and an empty entry is filtered out
// rather than turning into a lookup against the current directory.
process.env.NODE_PATH = [dirB, ''].join(path.delimiter);
Module._initPaths();
assert.ok(Module.globalPaths.includes(dirB));
assert.ok(!Module.globalPaths.includes(''));
assert.strictEqual(require.resolve('mobile-nodepath-b'),
                   path.join(dirB, 'mobile-nodepath-b.js'));
