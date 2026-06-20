// vcsr runtime host (the `js` FFI substrate) for the dashboard app.
// DOM nodes cross the WASM↔host boundary as INTEGER HANDLES (an index into a
// JS-side table) — the portable bridge documented in docs/WASM-ABI.md, since a
// C/clang module cannot persist `externref`. Strings cross as (ptr,len) into the
// module's shared linear memory; events call back into the module via dispatch().
const CORE = '__CORE_WASM__';

let mem = null, X = null;
const td = new TextDecoder(), te = new TextEncoder();
const u8 = () => new Uint8Array(mem.buffer);
const rd = (p, l) => td.decode(new Uint8Array(mem.buffer, p, l));
const wr = (p, s) => { const b = te.encode(s); u8().set(b, p); return b.length; };

const handles = [];                       // handle table: int -> DOM node/object
const ref = (o) => { handles.push(o); return handles.length - 1; };
const get = (h) => handles[h];

const env = {
  host_log: (p, l) => console.log('[wasm]', rd(p, l)),
  el_body: () => ref(document.body),
  el_create: (tp, tl) => ref(document.createElement(rd(tp, tl))),
  el_text: (h, p, l) => { get(h).textContent = rd(p, l); },
  el_attr: (h, np, nl, vp, vl) => { get(h).setAttribute(rd(np, nl), rd(vp, vl)); },
  el_class: (h, p, l) => { get(h).className = rd(p, l); },
  el_append: (parent, child) => { get(parent).appendChild(get(child)); },
  el_clear: (h) => { get(h).innerHTML = ''; },
  el_on: (h, ep, el, cbId, data) => { get(h).addEventListener(rd(ep, el), (e) => {
    if (e.cancelable) e.preventDefault();
    X.dispatch(cbId, data);
  }); },
  el_value: (h, outPtr) => wr(outPtr, get(h).value || ''),
  ls_set: (kp, kl, vp, vl) => { try { localStorage.setItem(rd(kp, kl), rd(vp, vl)); } catch (_) {} },
  ls_get: (kp, kl, outPtr) => { let v = ''; try { v = localStorage.getItem(rd(kp, kl)) || ''; } catch (_) {} return wr(outPtr, v); },
  time_str: (outPtr) => wr(outPtr, new Date().toTimeString().slice(0, 8)),
  fetch_text: (up, ul, cbId) => {
    const url = rd(up, ul);
    fetch(url).then(r => r.text()).then(text => {
      const dst = X.fetch_buf();                 // module-owned scratch buffer
      const b = te.encode(text);
      const n = Math.min(b.length, X.fetch_cap());
      u8().set(b.subarray(0, n), dst);
      X.on_fetch(cbId, dst, n);                  // async result -> module callback
    }).catch(e => console.error('fetch failed', e));
  },
};

(async () => {
  try {
    const { instance } = await WebAssembly.instantiateStreaming(fetch(CORE), { env });
    X = instance.exports; mem = X.memory;
    X.mount();
    // mirror the app's theme class (set on <body> by the wasm) onto <html> so the
    // page background fills the viewport canvas, not just the app subtree.
    const sync = () => { document.documentElement.className = document.body.className; };
    new MutationObserver(sync).observe(document.body, { attributes: true, attributeFilter: ['class'] });
    sync();
    document.documentElement.setAttribute('data-vcsr', 'mounted');
  } catch (e) {
    document.documentElement.setAttribute('data-vcsr-error', String(e));
    console.error(e);
  }
})();
