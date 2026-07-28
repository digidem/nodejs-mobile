'use strict';

const common = require('../common');
const assert = require('assert');
const fs = require('fs');

for (let i = 0; i < 12; i++) {
  fs.open(__filename, 'r', common.mustCall());
}

// nodejs-mobile patch: mobile keeps one extra stdio handle active for the life
// of the process — see test-process-getactiveresources.
const extraHandles = common.isAndroid || common.isIOS ? 1 : 0;

assert.strictEqual(process.getActiveResourcesInfo().length, 12 + extraHandles);
