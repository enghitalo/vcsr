// vcsr_host.js — the browser side of vcsr's DOM ABI (runtime/vcsr_host.h).
//
// OWNED BY vcsr: `vcsr wasm` rewrites this file next to core.wasm on every
// build, so the imports a module needs and the JS that provides them can't
// drift apart. Put your page's own code in app.js, which imports boot() from
// here (vcsr writes a default app.js once and never overwrites it).
//
// The wasm module owns no DOM: it asks the host to parse its template skeletons
// once, clone them, and patch the slot nodes it holds by integer handle. DOM
// nodes cross the boundary as indices into H; strings as (ptr, len) into the
// module's linear memory.

const td = new TextDecoder();
const te = new TextEncoder();

// nthComment returns the k-th comment child of `el` — a slot anchor (`<!---->`).
function nthComment(el, k) {
  let seen = 0;
  for (const n of el.childNodes) {
    if (n.nodeType === Node.COMMENT_NODE && seen++ === k) return n;
  }
  throw new Error(`vcsr: anchor ${k} not found in <${el.localName}>`);
}

export async function boot(wasmUrl = './core.wasm') {
  let exp = null;
  const mem = () => exp.memory;
  const rd = (p, l) => td.decode(new Uint8Array(mem().buffer, p, l));

  const H = [];                          // handle table: int -> DOM node
  const ref = (o) => { H.push(o); return H.length - 1; };

  const env = {
    // templates: the host's HTML parser builds each skeleton once
    host_register_template(p, l) {
      const t = document.createElement('template');
      t.innerHTML = rd(p, l).trim();
      return ref(t);
    },
    host_clone(t) { return ref(H[t].content.firstElementChild.cloneNode(true)); },
    // walk element children by the integer path (DOM .children is element-only)
    host_slot_at(root, pathPtr, n) {
      const dv = new DataView(mem().buffer);
      let cur = H[root];
      for (let k = 0; k < n; k++) cur = cur.children[dv.getInt32(pathPtr + k * 4, true)];
      return ref(cur);
    },
    // anchors: the k-th comment child of a node, or a text node placed before it
    host_anchor_at(h, k) { return ref(nthComment(H[h], k)); },
    host_anchor_text(h, k) {
      const a = nthComment(H[h], k);
      const t = document.createTextNode('');
      a.parentNode.insertBefore(t, a);
      return ref(t);
    },
    // patches
    host_set_text(h, p, l) { H[h].textContent = rd(p, l); },
    host_set_attr(h, np, nl, vp, vl) { H[h].setAttribute(rd(np, nl), rd(vp, vl)); },
    host_set_value(h, p, l) { H[h].value = rd(p, l); },
    host_set_visible(h, v) { H[h].style.display = v ? '' : 'none'; },
    // events: the module is called back by index; default actions are left alone
    host_on(h, ep, el, cb) { H[h].addEventListener(rd(ep, el), () => exp.vcsr_dispatch(cb)); },
    host_on_input(h, cb) {
      H[h].addEventListener('input', (e) => {
        const b = te.encode(e.target.value ?? '');
        const p = exp.vcsr_input_ptr(b.length);
        new Uint8Array(mem().buffer).set(b, p);
        exp.vcsr_dispatch_input(cb, p, b.length);
      });
    },
    host_mount(root, sp, sl) {
      const sel = rd(sp, sl);
      const host = document.querySelector(sel);
      if (!host) throw new Error(`vcsr: mount target ${sel} not found`);
      host.appendChild(H[root]);
    },
  };

  // V's libc imports a WASI surface; a page has none, so stub it (stdout goes
  // to the console, randomness to crypto, everything else is a no-op).
  const OK = 0;
  const wasi = new Proxy({
    proc_exit: (c) => { throw new Error('vcsr: wasm called proc_exit(' + c + ')'); },
    fd_write: (fd, iovs, n, nwritten) => {
      const dv = new DataView(mem().buffer);
      let total = 0;
      for (let i = 0; i < n; i++) {
        const p = dv.getUint32(iovs + i * 8, true), l = dv.getUint32(iovs + i * 8 + 4, true);
        (fd === 2 ? console.error : console.log)('[wasm]', rd(p, l));
        total += l;
      }
      dv.setUint32(nwritten, total, true);
      return OK;
    },
    random_get: (p, l) => { crypto.getRandomValues(new Uint8Array(mem().buffer, p, l)); return OK; },
  }, { get: (t, k) => (k in t ? t[k] : () => OK) });

  const root = document.documentElement;
  try {
    const imports = { env, wasi_snapshot_preview1: wasi };
    const res = fetch(wasmUrl);
    let instance;
    try {
      ({ instance } = await WebAssembly.instantiateStreaming(res, imports));
    } catch (e) {
      // a server without `Content-Type: application/wasm` (e.g. python -m http.server
      // on some systems) can't stream; fall back to a buffered compile
      if (!(e instanceof TypeError)) throw e;
      ({ instance } = await WebAssembly.instantiate(await (await fetch(wasmUrl)).arrayBuffer(), imports));
    }
    exp = instance.exports;
    exp._initialize();   // reactor: run libc constructors
    exp._vinit(0, 0);    // V: initialize globals (a reactor never runs main)
    exp.boot();          // the module's entry: build + mount the root view
    root.setAttribute('data-vcsr', 'mounted');
    return exp;
  } catch (e) {
    root.setAttribute('data-vcsr-error', String(e));
    console.error(e);
    throw e;
  }
}
