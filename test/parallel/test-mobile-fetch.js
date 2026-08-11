'use strict';

// Mobile gate for the global `fetch()` (see "Does fetch() work? What about
// WebAssembly?" in docs/FAQ.md on the recipe branch).
//
// undici parses HTTP with a WebAssembly build of llhttp, and the iOS build
// runs V8 jitless -- Apple forbids JIT -- which leaves V8 with no WebAssembly
// implementation at all, so `fetch()` used to fail with `WebAssembly is not
// defined`. The binary now carries a pure-JS polyfill (deps/polywasm) that
// internal/process/pre_execution installs when the engine has none.
//
// The same test therefore runs everywhere: against V8's own WebAssembly on
// Android and on the host, against the polyfill on iOS (and on any host
// binary run with --jitless, which is how CI exercises the polyfill without
// a device).

const common = require('../common');
const assert = require('assert');
const http = require('http');

// (module (func (export "add") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add))
const addModule = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
  0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
  0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
  0x00, 0x20, 0x01, 0x6a, 0x0b,
]);

async function main() {
  assert.strictEqual(typeof WebAssembly, 'object');
  assert.strictEqual(typeof WebAssembly.Module, 'function');

  // Which of the two is it? V8's constructors are native code; the polyfill is
  // plain JavaScript. Report it, and assert it when the caller says which one
  // this run is supposed to exercise -- otherwise a build that stopped needing
  // the polyfill (or stopped installing it) would still pass this test and the
  // gate would quietly stop covering the iOS path. The smoke-host CI job sets
  // it both ways; the device runs leave it unset and just take whatever the
  // binary has.
  const impl = /\[native code\]/.test(Function.prototype.toString.call(WebAssembly.Module)) ?
    'engine' : 'polyfill';
  console.log(`WebAssembly implementation: ${impl}`);
  const expected = process.env.NODEJS_MOBILE_EXPECT_WASM_IMPL;
  if (expected) {
    assert.strictEqual(impl, expected);
  }

  // Whichever implementation it is, it compiles and runs a module...
  const { instance } = await WebAssembly.instantiate(addModule, {});
  assert.strictEqual(instance.exports.add(40, 2), 42);

  // ...and looks like V8's own global: writable, non-enumerable, configurable
  // data property (the polyfill is installed lazily and must not leak that).
  const desc = Object.getOwnPropertyDescriptor(globalThis, 'WebAssembly');
  assert.deepStrictEqual(
    { writable: desc.writable, enumerable: desc.enumerable, configurable: desc.configurable },
    { writable: true, enumerable: false, configurable: true },
  );

  const server = http.createServer(common.mustCall((req, res) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', common.mustCall(() => {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ method: req.method, url: req.url, body }));
    }));
  }, 2));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;

  const posted = await fetch(`${origin}/echo`, { method: 'POST', body: 'ping' });
  assert.strictEqual(posted.status, 200);
  assert.strictEqual(posted.headers.get('content-type'), 'application/json');
  assert.deepStrictEqual(await posted.json(),
                         { method: 'POST', url: '/echo', body: 'ping' });

  // A second request reuses the kept-alive socket, so the parser has to
  // reset and run again -- where a half-working llhttp shows up.
  const got = await fetch(`${origin}/again`);
  assert.strictEqual(got.status, 200);
  let bytes = 0;
  for await (const chunk of got.body) {
    bytes += chunk.length;
  }
  assert.ok(bytes > 0);

  // These come off the same undici load, and are just as dead without a
  // working WebAssembly.
  assert.strictEqual(new Response('x').status, 200);
  assert.strictEqual(new Request(`${origin}/`).method, 'GET');
  assert.strictEqual(new Headers({ a: 'b' }).get('a'), 'b');

  server.close();
}

main().then(common.mustCall());
