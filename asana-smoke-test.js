'use strict';

// Smoke test for Asana's Node.js builds. Run with the built binary:
//
//   node asana-smoke-test.js [--fips]
//
// Exits non-zero if any check fails. The checks cover properties LunaServer depends on
// that the upstream test suite does not assert for our configure flags.

const assert = require('assert');
const { AsyncLocalStorage } = require('async_hooks');
const { spawnSync } = require('child_process');
const crypto = require('crypto');
const tls = require('tls');
const v8 = require('v8');
const { Worker } = require('worker_threads');
const zlib = require('zlib');

const expectFips = process.argv.includes('--fips');
const results = [];

async function check(name, fn) {
  try {
    const detail = await fn();
    results.push({ name, ok: true, detail });
  } catch (err) {
    results.push({ name, ok: false, detail: err?.stack ?? String(err) });
  }
}

function heapLimitWithMaxOldSpace(mb) {
  const out = spawnSync(process.execPath, [
    `--max-old-space-size=${mb}`,
    '-p',
    'require("v8").getHeapStatistics().heap_size_limit',
  ], { encoding: 'utf8' });
  assert.strictEqual(out.status, 0, out.stderr);
  return Number(out.stdout.trim());
}

async function main() {
  const vars = process.config.variables;

  await check('version is Node 24', () => {
    assert.match(process.version, /^v24\./);
    return `${process.version} (modules ${process.versions.modules}, v8 ${process.versions.v8})`;
  });

  await check('pointer compression enabled, V8 sandbox disabled', () => {
    assert.strictEqual(vars.v8_enable_pointer_compression, 1);
    assert.strictEqual(vars.v8_enable_31bit_smis_on_64bit_arch, 1);
    assert.strictEqual(vars.v8_enable_sandbox, 0);
    assert.strictEqual(vars.v8_enable_pointer_compression_shared_cage, 0);
    return 'multi-cage pointer compression';
  });

  await check('heap is capped by the 4GB pointer compression cage', () => {
    const limit = heapLimitWithMaxOldSpace(8192);
    assert(limit <= 4.5 * 1024 ** 3, `heap_size_limit ${limit} exceeds the 4GB cage`);
    return `heap_size_limit with --max-old-space-size=8192: ${(limit / 1024 ** 3).toFixed(2)} GiB`;
  });

  await check('LunaServer startup flags are accepted', () => {
    const flags = ['--stack_trace_limit=1000', '--no-wasm-code-gc', '--expose-gc',
                   '--max-old-space-size=2000', '--max-semi-space-size=64'];
    const out = spawnSync(process.execPath, [...flags, '-e', 'gc()'], { encoding: 'utf8' });
    assert.strictEqual(out.status, 0, out.stderr);
    return flags.join(' ');
  });

  await check('Maglev is enabled', () => {
    assert.strictEqual(vars.v8_enable_maglev, 1);
  });

  await check('OpenSSL linkage matches the build flavor', () => {
    assert.strictEqual(Boolean(vars.node_shared_openssl), expectFips);
    return `openssl ${process.versions.openssl}, shared=${vars.node_shared_openssl}, ` +
      `getFips()=${crypto.getFips()}`;
  });

  await check('brotli rejects invalid block switches (CVE-2026-111497)', () => {
    const invalid = Buffer.from('200010414141fcffff07002228f00b60f7f41f000000', 'hex');
    assert.strictEqual(zlib.constants.BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH, -17);
    assert.throws(() => zlib.brotliDecompressSync(invalid),
                  { code: 'ERR__ERROR_FORMAT_BLOCK_SWITCH' });
  });

  await check('worker threads get their own heap', async () => {
    const used = await new Promise((resolve, reject) => {
      const worker = new Worker(`
        const { parentPort } = require('worker_threads');
        const chunks = [];
        for (let i = 0; i < 64; i++) chunks.push(new Array(256 * 1024).fill(i));
        parentPort.postMessage(require('v8').getHeapStatistics().used_heap_size);
      `, { eval: true });
      worker.once('message', resolve);
      worker.once('error', reject);
    });
    return `worker used_heap_size ${(used / 1024 ** 2).toFixed(0)} MiB`;
  });

  await check('WebAssembly memory can be reserved', async () => {
    // (module (memory (export "m") 1 65536))
    const bytes = Buffer.from('0061736d010000000506010101808004070501016d0200', 'hex');
    const { instance } = await WebAssembly.instantiate(bytes);
    instance.exports.m.grow(16);
    return `${instance.exports.m.buffer.byteLength} bytes`;
  });

  await check('full ICU is available', () => {
    const formatted = new Intl.DateTimeFormat('ja-JP', { month: 'long' }).format(new Date(0));
    assert.match(formatted, /月/);
    return formatted;
  });

  await check('AsyncLocalStorage propagates across await and timers', async () => {
    const als = new AsyncLocalStorage();
    const seen = await als.run('ctx', async () => {
      await new Promise((resolve) => setTimeout(resolve, 1));
      await null;
      return new Promise((resolve) => setImmediate(() => resolve(als.getStore())));
    });
    assert.strictEqual(seen, 'ctx');
  });

  await check('crypto and TLS basics', () => {
    const digest = crypto.createHash('sha256').update('asana').digest('hex');
    assert.strictEqual(digest.length, 64);
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const signature = crypto.sign('sha256', Buffer.from('x'), privateKey);
    assert(crypto.verify('sha256', Buffer.from('x'), publicKey, signature));
    tls.createSecureContext({ minVersion: 'TLSv1.2' });
  });

  await check('v8.serialize round-trips', () => {
    const value = { a: [1, 2, 3], b: new Map([['k', 'v']]), c: 2n ** 70n };
    assert.deepStrictEqual(v8.deserialize(v8.serialize(value)), value);
  });

  let failed = 0;
  for (const { name, ok, detail } of results) {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${detail ? `\n      ${detail}` : ''}`);
  }
  console.log(failed ? `\n${failed} check(s) failed` : '\nAll checks passed');
  process.exitCode = failed ? 1 : 0;
}

main();
