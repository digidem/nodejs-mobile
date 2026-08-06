'use strict';

// Mobile gate for KVStore::Clone() (patch 0008; see docs/PATCHES.md on the
// recipe branch).
//
// `new Worker(file)` without an `env` option means "give the thread a copy of
// process.env", which node implements in node_worker.cc by calling
// KVStore::Clone() on the parent's store. Clone() enumerates the environment
// and then reads each name back. Upstream treats a name that enumerates but
// does not resolve as fatal: it returns a null store, and the worker is then
// constructed around a null pointer.
//
// That combination is not hypothetical on Android. The bionic linker strips
// variables such as LD_PRELOAD out of a freshly started app process, so a
// name can be enumerated and then fail to resolve a moment later. The patch
// skips that one variable and keeps the rest of the clone.
//
// What is asserted here is the post-condition Clone() owes its caller: a
// default-env worker starts, and its environment is the parent's. The Android
// leg of the curated run is the one that can actually meet an unclonable
// variable (a revert shows up there as a dead worker); the host and iOS legs
// prove the same code path copies the environment faithfully, long values and
// all.

const common = require('../common');
const assert = require('assert');
const {
  Worker, isMainThread, parentPort,
} = require('worker_threads');

if (!isMainThread) {
  // The worker half: hand the parent the environment this thread was born
  // with, then exit.
  parentPort.postMessage({ ...process.env });
  return;
}

// Values that make the copy prove itself: an empty one, a non-ASCII one, and
// one long enough to overflow the stack buffer RealEnvStore::Get() starts
// with (256 bytes) so it has to reallocate and re-read.
const OWN = {
  NODEJS_MOBILE_ENV_PLAIN: 'plain',
  NODEJS_MOBILE_ENV_EMPTY: '',
  NODEJS_MOBILE_ENV_UNICODE: 'héllo-wörld-\u{1F600}',
  NODEJS_MOBILE_ENV_SPACED: 'a b\tc',
  NODEJS_MOBILE_ENV_LONG: 'x'.repeat(4096),
};
for (const [key, value] of Object.entries(OWN)) {
  process.env[key] = value;
}

// Snapshot the parent through the same enumerate-then-read pair Clone() uses:
// spreading process.env enumerates it and then queries each name, so a name
// that cannot be resolved drops out of both sides rather than only one.
const expected = { ...process.env };
for (const [key, value] of Object.entries(OWN)) {
  assert.strictEqual(expected[key], value, `parent env lost ${key}`);
}

function runWorker(options) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, options);
    let received;
    worker.on('message', (message) => { received = message; });
    worker.on('error', reject);
    worker.on('exit', common.mustCall((code) => {
      if (code !== 0) {
        reject(new Error(`worker exited with code ${code}`));
        return;
      }
      resolve(received);
    }));
  });
}

async function main() {
  // No `env` option: node clones the parent store. This is the patched path.
  const cloned = await runWorker({});
  assert.notStrictEqual(cloned, undefined,
                        'default-env worker never reported its environment');
  for (const [key, value] of Object.entries(expected)) {
    assert.strictEqual(cloned[key], value, `cloned env lost ${key}`);
  }

  // The neighbouring branch, as a control: an explicit `env` builds a fresh
  // store instead of cloning, so the parent's variables must not be there.
  // If this ever starts seeing them, the clone branch is being taken for
  // everything and the assertion above has stopped meaning anything.
  const explicit = await runWorker({ env: { NODEJS_MOBILE_ENV_ONLY: 'only' } });
  assert.strictEqual(explicit.NODEJS_MOBILE_ENV_ONLY, 'only');
  assert.strictEqual(explicit.NODEJS_MOBILE_ENV_PLAIN, undefined);
}

main().then(common.mustCall());
