'use strict';

const common = require('../common');

const assert = require('assert');

setTimeout(() => {}, 0);

// nodejs-mobile patch: the app hosts node on a background thread with stdio
// wired to a pipe (Android) or a tty (iOS) that stays referenced for the life
// of the process, so one extra handle is always active.
const expected = ['Timeout'];
if (common.isAndroid) {
  expected.unshift('PipeWrap');
} else if (common.isIOS) {
  expected.unshift('TTYWrap');
}

assert.deepStrictEqual(process.getActiveResourcesInfo(), expected);
