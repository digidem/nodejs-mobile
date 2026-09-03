'use strict';

// Mobile gate for unix domain sockets (no patch; a platform property this fork
// has to keep honest -- see docs/TESTING.md on the recipe branch).
//
// UDS works in both mobile sandboxes, but Darwin caps sockaddr_un.sun_path at
// 104 bytes where Linux allows 108, and the kernel stores the path *as given*.
// An iOS app's data container is already long -- ~81 bytes on a device, ~171 on
// the simulator, before any filename -- so an absolute path inside it does not
// fit, and bind() fails with EINVAL. That is a path-length limit, not a missing
// feature: the same socket binds fine when the path is short.
//
// Upstream's own common.PIPE builds a path relative to process.cwd() for
// exactly this reason, and the upstream UDS tests pass on the simulator only
// because the harness chdir()s the app to the on-device tree root, keeping
// that relative path short (docs/TESTING.md on the recipe branch). That is a
// harness behaviour, not a platform guarantee: an embedder's cwd is `/`
// unless it sets one, and no upstream test gates UDS without the harness's
// help.
//
// This is the gate that does. It chdir()s to the socket's directory and binds a short
// relative path, which is the portable way to use a unix socket on iOS and the
// pattern an embedder should follow. A regression here means UDS stopped
// working, rather than merely that a path got too long.

const common = require('../common');
const assert = require('assert');
const net = require('net');
const path = require('path');
const process = require('process');
const tmpdir = require('../common/tmpdir');

tmpdir.refresh();

// Bind from inside the directory so sun_path carries only the file name. Keep
// it short: the whole point is to stay clear of the 104-byte Darwin cap.
const cwd = process.cwd();
process.chdir(tmpdir.path);
process.on('exit', () => {
  try {
    process.chdir(cwd);
  } catch {
    // The original cwd may be unreachable in a sandbox; nothing to restore to.
  }
});

const SOCKET = './s.sock';
assert.ok(SOCKET.length < 104, 'the relative path must fit in sun_path');

const PAYLOAD = 'nodejs-mobile';

const server = net.createServer(common.mustCall((conn) => {
  conn.on('data', common.mustCall((chunk) => {
    conn.end(chunk);
  }));
}));

server.listen(SOCKET, common.mustCall(() => {
  const address = server.address();
  // A unix socket reports its path as a string, not an {address, port} object;
  // that is how an embedder tells the two families apart.
  assert.strictEqual(typeof address, 'string');

  const client = net.connect(SOCKET, common.mustCall(() => {
    client.write(PAYLOAD);
  }));

  let received = '';
  client.setEncoding('utf8');
  client.on('data', (chunk) => {
    received += chunk;
  });
  client.on('end', common.mustCall(() => {
    assert.strictEqual(received, PAYLOAD);
    server.close();
  }));
}));
