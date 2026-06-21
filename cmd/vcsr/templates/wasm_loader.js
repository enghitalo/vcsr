// app.js — default host loader emitted by `vcsr wasm` (edit freely; vcsr won't
// overwrite an existing app.js). Implements the vcsr DOM ABI (runtime/vcsr_host.h)
// against the real document, plus a minimal WASI shim, then calls the module's
// exported boot(). DOM nodes cross as integer handles; strings as (ptr,len).
const CORE = './core.wasm';

const td = new TextDecoder(), te = new TextEncoder();
let exp = null;
const mem = () => exp.memory;
const rd = (p, l) => td.decode(new Uint8Array(mem().buffer, p, l));

const H = [];                              // handle table: int -> DOM node
const ref = (o) => { H.push(o); return H.length - 1; };

const env = {
  host_register_template(p, l) { const t = document.createElement('template'); t.innerHTML = rd(p, l).trim(); return ref(t); },
  host_clone(t) { return ref(H[t].content.firstElementChild.cloneNode(true)); },
  host_slot_at(root, pathPtr, n) {
    const dv = new DataView(mem().buffer); let cur = H[root];
    for (let k = 0; k < n; k++) cur = cur.children[dv.getInt32(pathPtr + k * 4, true)];
    return ref(cur);
  },
  host_set_text(h, p, l) { H[h].textContent = rd(p, l); },
  host_set_attr(h, np, nl, vp, vl) { H[h].setAttribute(rd(np, nl), rd(vp, vl)); },
  host_set_value(h, p, l) { H[h].value = rd(p, l); },
  host_set_visible(h, v) { H[h].style.display = v ? '' : 'none'; },
  host_on(h, ep, el, cb) { H[h].addEventListener(rd(ep, el), (e) => { if (e.cancelable) e.preventDefault(); exp.vcsr_dispatch(cb); }); },
  host_on_input(h, cb) {
    H[h].addEventListener('input', (e) => {
      const b = te.encode(e.target.value ?? '');
      const p = exp.vcsr_input_ptr(b.length); new Uint8Array(mem().buffer).set(b, p);
      exp.vcsr_dispatch_input(cb, p, b.length);
    });
  },
  host_mount(root, sp, sl) { document.querySelector(rd(sp, sl)).appendChild(H[root]); },
};

const OK = 0;                              // minimal WASI shim (V's libc imports)
const wasi = new Proxy({
  proc_exit: (c) => { throw new Error('proc_exit ' + c); },
  fd_write: (fd, iovs, n, nwritten) => {
    const dv = new DataView(mem().buffer); let total = 0;
    for (let i = 0; i < n; i++) { const p = dv.getUint32(iovs + i * 8, true), l = dv.getUint32(iovs + i * 8 + 4, true);
      console.log('[wasm]', rd(p, l)); total += l; }
    dv.setUint32(nwritten, total, true); return OK;
  },
  random_get: (p, l) => { crypto.getRandomValues(new Uint8Array(mem().buffer, p, l)); return OK; },
}, { get: (t, k) => (k in t ? t[k] : () => OK) });

(async () => {
  const { instance } = await WebAssembly.instantiateStreaming(fetch(CORE), { env, wasi_snapshot_preview1: wasi });
  exp = instance.exports;
  exp._initialize();   // reactor: run libc constructors
  exp._vinit(0, 0);    // V: init global state (not auto-run under reactor)
  exp.boot();          // mount the app; DOM events drive it from here
  document.documentElement.setAttribute('data-vcsr', 'mounted');
})().catch((e) => { document.documentElement.setAttribute('data-vcsr-error', String(e)); console.error(e); });
