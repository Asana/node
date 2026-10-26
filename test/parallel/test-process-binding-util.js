'use strict';
require('../common');
const assert = require('assert');
const util = require('util');

const utilBinding = process.binding('util');
const legacyKeys = [
  'isAnyArrayBuffer',
  'isArrayBuffer',
  'isArrayBufferView',
  'isAsyncFunction',
  'isDataView',
  'isDate',
  'isExternal',
  'isMap',
  'isMapIterator',
  'isNativeError',
  'isPromise',
  'isRegExp',
  'isSet',
  'isSetIterator',
  'isTypedArray',
  'isUint8Array',
];

for (const k of legacyKeys) {
  assert.strictEqual(utilBinding[k], util.types[k], k);
}

// Asana: process.binding('util') also exposes internalBinding('util'), which LunaServer
// uses to synchronously read the state of settled promises.
const fulfilled = Promise.resolve(42);
assert.deepStrictEqual(utilBinding.getPromiseDetails(fulfilled),
                       [utilBinding.constants.kFulfilled, 42]);
assert.deepStrictEqual(utilBinding.getPromiseDetails(new Promise(() => {})),
                       [utilBinding.constants.kPending]);
