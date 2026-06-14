import http from 'node:http';
import { readFile } from 'node:fs/promises';

// A real local HTTP server with a known body — a genuine async network round-trip (loopback).
const BODY = 'PONG-from-server-42';
const server = http.createServer((_, res) => { res.writeHead(200, {'content-type':'text/plain'}); res.end(BODY); });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const URL_ = `http://127.0.0.1:${server.address().port}/data`;

const bytes = await readFile(new URL('./webapi.wasm', import.meta.url));
const enc = new TextEncoder(), dec = new TextDecoder();
let inst;
const u8  = () => new Uint8Array(inst.exports.memory.buffer);
const str = (p, l) => dec.decode(new Uint8Array(inst.exports.memory.buffer, p, l));
const FETCH_SCRATCH = 3072;
const lsMap = new Map();
let cbFired = false, startReturnedAt = 0, cbAt = 0;

const imports = { env: {
  log: (p, l) => console.log('     [wasm→log]', str(p, l)),
  ls_set: (kp,kl,vp,vl) => lsMap.set(str(kp,kl), str(vp,vl)),
  ls_get: (kp,kl,outp) => { const b = enc.encode(lsMap.get(str(kp,kl)) ?? ''); u8().set(b, outp); return b.length; },
  // ASYNC: return immediately; on resolution, write body into wasm memory and call the wasm callback via the TABLE.
  fetch_start: (urlp, urll, cbIdx) => {
    const url = str(urlp, urll);
    console.log('     [host] fetch_start →', url, '| wasm callback = table[' + cbIdx + '] (no JSPI, pure callback)');
    fetch(url).then(r => r.text()).then(text => {
      const b = enc.encode(text);
      u8().set(b, FETCH_SCRATCH);                                   // host writes response into wasm linear memory
      const cb = inst.exports.__indirect_function_table.get(cbIdx); // resolve the wasm func from the shared table
      cbFired = true; cbAt = performance.now();
      cb(7 /*reqId*/, FETCH_SCRATCH, b.length);                     // host → wasm callback
    });
  },
}};

inst = (await WebAssembly.instantiate(bytes, imports)).instance;

console.log('1) SYNC  localStorage:');
const n = inst.exports.ls_demo();
console.log(`     stored+read back ${n} bytes; backing store =`, [...lsMap]);

console.log('2) ASYNC fetch (portable callback model):');
const t0 = performance.now();
inst.exports.start(URL_.length, u8().set(enc.encode(URL_), 16));   // host put URL at offset 16; wasm forwards (16,len)
startReturnedAt = performance.now();
console.log(`     start() returned in ${(startReturnedAt-t0).toFixed(2)}ms; wasm result()=${inst.exports.result()} (0 ⇒ did NOT block)`);
await new Promise(r => setTimeout(r, 300));                        // let the real fetch + callback complete
console.log(`     after await: callback fired=${cbFired}; wasm result()=${inst.exports.result()} (expected ${BODY.length})`);

server.close();
const ok = cbFired && inst.exports.result() === BODY.length && inst.exports.result() !== undefined;
console.log(ok ? '\n✅ PASS — async fetch round-trip via __indirect_function_table; sync localStorage via imports' : '\n❌ FAIL');
process.exit(ok ? 0 : 1);
