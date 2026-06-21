// Runs the closure-free reactive counter (app.wasm) the way a browser would: a
// minimal `wasi_snapshot_preview1` shim (V's libc imports) + an `env.host_set_text`
// that stands in for the DOM node's textContent setter. Proves the full path:
// compiled-V reactive update -> (ptr,len) FFI -> host, with an event re-render.
//
//   node harness.mjs        # Node 18+ (measured on Node 26)
import { readFile } from 'node:fs/promises';

const bytes = await readFile(new URL('./app.wasm', import.meta.url));
const td = new TextDecoder();
let exp = null;
let domText = null; // the mounted node's textContent, in a browser

// env: the vcsr host boundary. host_set_text reads (ptr,len) from wasm memory.
const env = {
  host_set_text: (ptr, len) => {
    domText = td.decode(new Uint8Array(exp.memory.buffer, ptr, len));
    console.log('   host_set_text ->', JSON.stringify(domText));
  },
};

// Minimal WASI shim: succeed-noop for everything; real fd_write -> console,
// random_get -> crypto. (V's reactor module imports ~45 WASI calls; only a few
// are exercised. A browser bundle would ship this same shim in app.js.)
const OK = 0;
const wasi = new Proxy({
  proc_exit: (c) => { throw new Error('proc_exit ' + c); },
  fd_write: (fd, iovs, n, nwritten) => {
    const dv = new DataView(exp.memory.buffer); let total = 0;
    for (let i = 0; i < n; i++) {
      const p = dv.getUint32(iovs + i * 8, true), l = dv.getUint32(iovs + i * 8 + 4, true);
      process.stdout.write('[wasm] ' + td.decode(new Uint8Array(exp.memory.buffer, p, l)));
      total += l;
    }
    dv.setUint32(nwritten, total, true); return OK;
  },
  random_get: (p, l) => { crypto.getRandomValues(new Uint8Array(exp.memory.buffer, p, l)); return OK; },
}, { get: (t, k) => (k in t ? t[k] : () => OK) });

const { instance } = await WebAssembly.instantiate(bytes, { env, wasi_snapshot_preview1: wasi });
exp = instance.exports;
exp._initialize();  // reactor: run libc constructors
exp._vinit(0, 0);   // V: initialize global state (NOT auto-run under reactor — see README)

console.log('boot():'); exp.boot();
console.log('inc():');  exp.inc();
console.log('inc():');  exp.inc();
console.log('inc():');  exp.inc();

const ok = domText === '3';
console.log(ok
  ? '\n✅ PASS — closure-free reactive counter compiled from V ran in wasm; a signal write re-ran the effect and drove the host via (ptr,len) FFI. Final DOM text = "3".'
  : '\n❌ FAIL — final domText=' + JSON.stringify(domText));
process.exit(ok ? 0 : 1);
