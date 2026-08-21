'use strict';
// Real-device smoke (BrowserStack App Automate): prove the shipped
// binary boots and runs JavaScript on physical hardware, then run the
// crc-native N-API addon gate (the "B-1" concern: napi_* resolution via a real
// process.dlopen on a device loader). Runs alongside test-napi-addon.js, which
// the harness stages next to this file; NODE_MOBILE_ADDON is set by the
// testnode native layer to the staged addon's path.
//
// No process.exit(): let the event loop drain so the embedder returns exit
// code 0 and the testnode harness reports a clean PASS verdict.
console.log(
  `NODEJS_MOBILE_SMOKE_OK ${process.version} ${process.platform} ${process.arch}`,
);
require('./test-napi-addon.js');
console.log('NODEJS_MOBILE_BS_SMOKE_DONE');
