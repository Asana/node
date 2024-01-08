'use strict';
require('../common');
const assert = require('assert');
const util = require('util');

const utilBinding = process.binding('util');
assert.deepStrictEqual(
  Object.keys(utilBinding).sort(),
  [
    'WeakReference',
    'arrayBufferViewHasBuffer',
    'constants',
    'getCallerLocation',
    'getConstructorName',
    'getExternalValue',
    'getOwnNonIndexProperties',
    'getPromiseDetails',
    'getProxyDetails',
    'guessHandleType',
    'isAnyArrayBuffer',
    'isArrayBuffer',
    'isArrayBufferDetached',
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
    'previewEntries',
    'privateSymbols',
    'shouldAbortOnUncaughtToggle',
    'sleep',
    'toUSVString'
  ]);

for (const k of Object.keys(utilBinding)) {
  if (k in util.types) {
    assert.strictEqual(utilBinding[k], util.types[k]);
  }
}
