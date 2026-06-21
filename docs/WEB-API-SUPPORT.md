# Web-API support status — can a vcsr component use these resources *today*?

Companion to [WASM-PATHS-ANALYSIS.md](WASM-PATHS-ANALYSIS.md) §5. That section
proves the **mechanism** by which WASM reaches each browser resource (an imported
JS function + `(ptr,len)` marshalling for sync; a `__indirect_function_table`
callback for async). This document answers a narrower, practical question:

> **Can I write a single example that *works* using all of these resources right now?**

**Short answer: no — not from a vcsr component.** The mechanisms are real and two
of them are demonstrated in this repo, but they are reachable only from
**hand-written C / `.wat` fixtures**, not from a V-authored component compiled by
the `vcsr` toolchain. Verified against the tree on **2026-06-21** (V `0.5.1`).

> **Update (2026-06-21) — the synchronous half is now built and tested.** The six
> sync resources are reachable from V through the generic FFI against the native
> mock (`global().get('localStorage').call('getItem', …)`, `…get('history')
> .call('pushState', …)`, etc.) and unit-tested in
> [`tests/phase_16_runtime_webapi_test.v`](../tests/phase_16_runtime_webapi_test.v);
> the **default generated loader** now wires the matching host imports
> (`ls_*`/`ss_*`, `host_log`, `random_get`, `loc_read`, `history_push`), asserted
> by [`phase 08`](../tests/phase_08_bundle_emit_test.v). See
> [`webapi_mock.v`](../webapi_mock.v) and [`bundle/bundle.v`](../bundle/bundle.v).
> This moves the sync rows to **V-substrate ✅ / wired ⚠️**. End-to-end (level 4)
> stays ❌ for *all* rows — still blocked by Gate 1 (no V→browser-wasm). The async
> resources (`fetch`, timers, sockets, IndexedDB) are unchanged: ❌, by design,
> until a host-deferred callback dispatcher exists (Gate 2).

---

## The four levels of "supported"

"Supported" is ambiguous, so every resource below is rated on four independent
axes. They are *not* the same thing, and most of the confusion about this table
comes from conflating the first with the last.

| Level | Question | Where it lives |
| --- | --- | --- |
| **1 · Mechanism** | Does an isolated hand-written `.wat`/`.js` in this repo prove the WASM↔host round-trip? | [`docs/examples/webapi-demo/`](examples/webapi-demo/), [`testdata/dashboard-app/`](../testdata/dashboard-app/) |
| **2 · V substrate** | Can V code *express* the call through the `js` FFI as it exists? | [`js_ffi.v`](../js_ffi.v) |
| **3 · Wired** | Is it exposed by the vcsr runtime / codegen / the **default generated** loader? | [`runtime/`](../runtime/), [`bundle/bundle.v`](../bundle/bundle.v) |
| **4 · End-to-end** | Could a real vcsr component, compiled and mounted in a browser **today, with no new framework code**, use it? | — |

A resource can be ✅ at level 1 and ❌ at level 4 — and most are. A proof in a
hand-coded `.wat` is **not** the same as a capability a vcsr component can use.

---

## The matrix

| Resource (from §5) | 1 · Mechanism | 2 · V substrate | 3 · Wired | 4 · End-to-end | One-line status |
| --- | :---: | :---: | :---: | :---: | --- |
| `localStorage` / `sessionStorage` | ✅ | ✅ | ⚠️ | ❌ | **Mock substrate + default loader now wire `ls_*`/`ss_*`** ([phase 16](../tests/phase_16_runtime_webapi_test.v)); browser path untested until Gate 1 |
| `crypto.getRandomValues` | ❌ | ✅ | ⚠️ | ❌ | **Now in the mock (via `js_array`) + `random_get` in the default loader**; no in-repo `.wat` harness, so the byte-write mechanism itself is still unproven |
| `console` (log) | ✅ | ✅ | ⚠️ | ❌ | **Mock `console.*` + `host_log` in the default loader**; reachable from V against the mock |
| `URL` parsing | ❌ | ✅ | ⚠️ | ❌ | **Mock `URL` constructor parses components**; in a browser `URL` is a real global reached via `global()` (no flat shim needed) |
| read `location` | ❌ | ✅ | ⚠️ | ❌ | **Mock `location` + `loc_read` in the default loader**; the router still does no host calls |
| History `pushState` | ⚠️ | ✅ | ⚠️ | ❌ | **Mock `history.pushState` updates `location` + `history_push` in the default loader**; router still compile-time only |
| **`fetch`** | ✅ | ❌ | ❌ | ❌ | Async callback model proven in `webapi-demo` (runs, passes) + dashboard — but no async in the V mock, no dispatcher in the runtime |
| `WebSocket` / `EventSource` | ⚠️ | ⚠️→❌ | ❌ | ❌ | Pure vapor; only the *adjacent* fetch / DOM-event callback pattern is proven |
| DOM events | ✅ | ⚠️ | ❌ | ❌ | Click/input proven end-to-end in real Chromium — but via hand-written C, and only manual `dispatch()` in the V runtime |
| `setTimeout` / `requestAnimationFrame` | ❌ | ❌ | ❌ | ❌ | Documented only; mechanism never demonstrated, mock can't model a deferred callback |
| IndexedDB | ⚠️ | ❌ | ❌ | ❌ | Documented only; weakest of all — one matrix row, zero code |

Legend: ✅ yes · ⚠️ partial / in principle · ❌ no.

**Level 4 is ❌ for every row.** No vcsr-authored component can use *any* of these
in a browser today, for the three structural reasons below.

---

## Why end-to-end is ❌ everywhere — three gates, in order

### Gate 1 — There is no V→browser-wasm compile path

This blocks *all* eight categories before any per-resource detail matters.

- `vcsr gen` only parses a `.v`/`.html`/`.css` triplet and emits **plain V**
  (`*.gen.v`) that runs against the **native mock runtime**, not WASM
  ([`cmd/vcsr/vcsr.v:48-65`](../cmd/vcsr/vcsr.v#L48)). The generated
  [`counter.gen.v`](../examples/counter/src/counter.gen.v) imports only
  `vcsr.runtime` and calls `bind_text`/`bind_event` — it never touches the `js`
  FFI or the DOM.
- `vcsr build` **hard-errors** unless the app ships a *prebuilt* browser-ABI
  `core.wasm` in `build/`, with the inline note *"V cannot emit browser wasm
  yet"* ([`cmd/vcsr/vcsr.v:75-86`](../cmd/vcsr/vcsr.v#L75)).
- The only thing that actually runs in a browser is
  [`testdata/dashboard-app/`](../testdata/dashboard-app/) — and its core is
  **hand-written C** (`src/app.c`, 8.6 KB) compiled to `core.wasm`, with a
  **hand-authored** `src/loader.js`. There is no `.v` file in it. That is a
  bespoke fixture, not a vcsr component.

→ A V-authored component cannot be compiled to a browser module by the toolchain
at all. See [WASM-PATHS-ANALYSIS.md](WASM-PATHS-ANALYSIS.md) §6 — Path 2
(`v -cc clang` + wasi-sdk) is the intended route but is not wired into the CLI.

> **Update (2026-06-21) — toolchain works; TWO V-on-wasm blockers, one fixed.**
> The Path 2 spine is verified end-to-end: `v -cc clang` + wasi-sdk compiles a V
> module (and the whole vcsr runtime) to a valid, loadable `core.wasm` that runs
> in Node/V8. Two execution-level V limitations surfaced (both "validate but don't
> run" — see the corrected [WASM-PATHS §2.1](WASM-PATHS-ANALYSIS.md)):
>
> 1. **Capturing closures trap** (`fn [x] () {...}` needs executable memory wasm
>    forbids). The runtime's effects + every `bind_*` getter/handler were closures.
>    **FIXED & LANDED:** `signal.v`, `runtime` (`bind_*_ctx`), and the codegen are
>    now closure-free (effect = top-level fn + `voidptr` ctx; generic `Cleanup`
>    detach); all 17 native test files stay green. Proven to run in wasm by
>    [examples/wasm-reactive/](examples/wasm-reactive/) (`boot()→"0"`,
>    `inc()→"1"→"2"→"3"`).
> 2. **String-keyed maps fail at runtime** — `map[string]V` validates but lookups
>    return the zero value (insert works, `m.len` is right, retrieval can't find
>    the key; a second op panics `Probe overflow`). Localized: int-keyed maps and
>    wyhash both work, so it's V's map string-key clone/equality path on wasm.
>    The runtime uses `map[string]…` in the template parser (attr maps),
>    `Node.attrs`, and the event map, so the **mock-tree backend can't run on
>    wasm**. NOT yet resolved.
>
> So Gate 1's remaining work was a **host-owned-DOM, map-free wasm rendering
> backend**: the host parses the template and owns DOM nodes (by integer handle);
> the V side keeps only the reactive logic (signals/effects — closure- and
> map-free) plus FFI calls, using arrays / int-keys, never `map[string]` and never
> the V parser at runtime.
>
> **Update 2 (2026-06-21) — Gate 1 CLOSED for the counter; it runs in a browser.**
> Built and verified end-to-end:
> - `runtime/backend_wasm_d_wasm_browser.v` — the map-free, closure-free wasm
>   backend (host DOM ABI in `runtime/vcsr_host.h`), selected by `-d wasm_browser`
>   via V's conditional-file compilation; the native mock tree
>   (`backend_native_notd_wasm_browser.v`) is unchanged and all **17 native test
>   files stay green**.
> - `vcsr wasm <component-src>` — compiles a V component to `core.wasm` via
>   `v -cc clang` + wasi-sdk (the recipe is now a CLI command).
> - [examples/counter/wasm/](examples/counter/wasm/) — the **generated** counter
>   component compiled to `core.wasm`, with a browser loader (`app.js`) + page.
>   Verified **in real headless Chromium** (`tools/browser-smoke/counter-smoke.mjs`):
>   clicking the wasm-rendered `+1` button re-patches `<h1>`=count and
>   `<span>`=doubled (0→1→3 / 0→2→6) through the host DOM FFI — and in Node/V8
>   (`examples/counter/wasm/smoke.mjs`).
>
> `vcsr wasm <src>` now emits a complete, runnable bundle — `core.wasm` **plus** a
> default `app.js` (DOM-ABI host loader + WASI shim) and `index.html` (it won't
> clobber a customized one) — so `vcsr wasm` + `vcsr serve` opens in a browser with
> no hand-written JS (verified against the emitted default in Chromium).
>
> Still future work: a map-free wasm **App/router** (the App layer is native-only
> — it leans on the `js_ffi` mock whose maps don't run on wasm); injecting the
> component's scoped `style()` CSS on the wasm path; and `@for` keyed-list render.

### Gate 2 — The `js` FFI is a **synchronous** native mock

Even ignoring Gate 1, half the resources are async and the substrate cannot model
async at all.

- `JsCell` is `JsCallback | JsNull | JsObject | JsUndefined | bool | f64 | string`
  ([`js_ffi.v:51`](../js_ffi.v#L51)) — there is **no Promise/future cell**, and
  no `Uint8Array`/linear-memory-view cell (so even sync `getRandomValues`, which
  writes bytes into a memory view, has nowhere to deposit them).
- `call` / `invoke` / `new` ([`js_ffi.v:227-256`](../js_ffi.v#L227)) run a
  `JsCallback` **inline and synchronously** and return immediately. Nothing lets
  the host retain a callback and fire it **later** — the defining requirement of
  `fetch`, `setTimeout`/rAF, `WebSocket`/`EventSource`, and IndexedDB.
- The only host→guest path in the runtime is `Instance.dispatch(i, event)`
  ([`runtime/runtime.v:212-217`](../runtime/runtime.v#L212)), a **manual**
  synchronous DOM-event fire. There is no event loop, no microtask queue, no
  `on_mount` lifecycle hook, no async callback dispatcher.

→ `fetch`, timers, sockets, and IndexedDB are **unrepresentable** in V as it
exists — they cannot even be unit-tested on the native backend, let alone run.
The sync resources (`localStorage`, `console`, `URL`, `location`, `pushState`)
were also unreachable until 2026-06-21 — the mock `global()` was an empty object
with none of these objects attached — but they are now installed by
[`webapi_mock.v`](../webapi_mock.v) (`install_webapi()`) and exercised from V in
[phase 16](../tests/phase_16_runtime_webapi_test.v). The async wall stands; the
sync wall is down. (`crypto`'s byte buffer is modelled over an array-like
`js_array`, since `JsCell` still has no typed-array cell.)

### Gate 3 — The **default generated** loader and the async hole *(sync part now closed)*

- Until 2026-06-21 the generated [`bundle.v` `loader_js()`](../bundle/bundle.v#L293)
  emitted only `register_template`, `clone_template`, `set_text`. It now also
  wires the **synchronous** Web-API imports — `host_log`, `ls_get`/`ls_set`,
  `ss_get`/`ss_set`, `random_get`, `loc_read`, `history_push`
  ([`bundle/bundle.v`](../bundle/bundle.v#L306)) — each the same `(ptr,len)`
  shape as `set_text`, asserted by
  [phase 08](../tests/phase_08_bundle_emit_test.v) and `node --check`-valid.
- Still **not** in the generated loader: every **async** import (`fetch_text`/
  `on_fetch`, `ws_open`, timers, IDB) — those need the Gate 2 dispatcher first.
  The hand-authored
  [`testdata/dashboard-app/src/loader.js`](../testdata/dashboard-app/src/loader.js)
  remains the only place async (`fetch_text`→`on_fetch`) and DOM events (`el_on`)
  are wired.

→ A generated component can now reach the **six sync** resources through the
default loader — but it still cannot *invoke* them, because no codegen emits the
imports and (Gate 1) no V component compiles to wasm at all. The **four async**
categories remain unreachable everywhere but the hand-written dashboard fixture.

---

## What is genuinely proven (level 1) — and what it isn't

To be fair to the design: the *hard part* (the async ABI) is demonstrated and
reproducible.

- **`fetch` (async, no JSPI):**
  [`webapi-demo/webapi.wat`](examples/webapi-demo/webapi.wat) +
  [`harness.mjs`](examples/webapi-demo/harness.mjs) prove the portable callback
  model — `fetch_start` returns immediately (`result()=0`, non-blocking), the body
  lands only when the host writes linear memory and calls back via
  `__indirect_function_table.get(1)`. It runs and passes under Node 26.
- **`localStorage` (sync) + DOM events + `fetch`:** the dashboard fixture
  ([`loader.js`](../testdata/dashboard-app/src/loader.js) + `app.c`) is driven in
  **real Chromium** by [`dashboard-smoke.mjs`](../tools/browser-smoke/), which
  toggles a theme, reloads, and asserts persistence across reload.

But every one of these is **hand-written C / `.wat`**, not vcsr output, and the
async categories that aren't `fetch` (`setTimeout`/rAF, `WebSocket`/`EventSource`,
IndexedDB) are **not demonstrated even once** — they are reused-pattern claims,
not running code. `crypto.getRandomValues`, `URL`, and `location` have **zero**
presence in the repo (the `random_get` referenced in §5 is in the *external*
`~/Documents/concept-examples`, a WASI shim, not vcsr).

The aspirational shape is sketched in
[`examples/spa/src/components/reports.v`](../examples/spa/src/components/reports.v)
— `import dom { fetch }`, `on_mount`, `spawn r.load()`, `router.param('id')` — but
the file header says *"Illustrative source"* and **none of those symbols exist**
in the codebase.

---

## What it would take to reach a working all-resources example

Grouped by gate, smallest-first:

1. **Close Gate 3 (sync resources — low effort).** ✅ **Done (2026-06-21).**
   [`webapi_mock.v`](../webapi_mock.v) populates the mock `global()` with
   `localStorage`/`sessionStorage`, `console`, `URL`, `location`, `history`, and
   `crypto` (call `install_webapi()`); `bundle.v`'s `loader_js()` now emits the
   matching `(ptr,len)` host imports (`ls_*`/`ss_*`, `host_log`, `random_get`,
   `loc_read`, `history_push`). Tested by
   [phase 16](../tests/phase_16_runtime_webapi_test.v) (mock) and
   [phase 08](../tests/phase_08_bundle_emit_test.v) (loader generation). The
   browser path stays unverifiable until Gate 1 lands.
2. **Close Gate 2 (async — design work).** Add (a) a Promise/deferred cell + a
   pending-callback queue to the `js_ffi.v` mock so a stored `JsCallback` can fire
   *after* the current call returns; (b) an `on_mount`/lifecycle hook in
   `runtime/app.v`; (c) a real host→guest **callback dispatcher** that registers a
   V callback into `__indirect_function_table` and an exported entry point the
   host invokes on resolution (the `on_response`/`on_fetch` pattern, but
   generated). This unlocks `fetch`, timers, sockets, IndexedDB together.
3. **Close Gate 1 (the runtime refactor — the big one).** 🟡 **Path proven
   (2026-06-21);** see [examples/wasm-reactive/](examples/wasm-reactive/). The
   `v -cc clang` + wasi-sdk toolchain is verified to compile and run V in wasm —
   but V's *capturing closures* trap there (executable-memory thunk), and the
   runtime is closure-based, so the work is a refactor, not just wiring:
   (a) make `signal.v` closure-free (effect = top-level fn + `voidptr` ctx;
   re-solve the generic `Signal[T]` cleanup typed-ly); (b) make `runtime.bind_*`
   + `counter.gen.v` codegen emit context structs, not captured closures;
   (c) add a wasm DOM backend (imported `el_*` FFI ops vs the in-memory mock);
   (d) wire the `v -cc clang` recipe into `vcsr build`, replacing the
   "prebuilt wasm required" gate.

### The one thing you *can* do today

If the goal is a single artifact that touches all eight resources **right now**,
the only path is to **hand-write it like the dashboard**: author a `core.wasm`
(C/`.wat`) and a custom `src/loader.js` exposing all eight host functions, then
`vcsr build` + `vcsr serve` it. That is not "a vcsr component," and the six
currently-absent categories (`crypto`, `URL`, `location`, `history`,
timers/rAF, sockets, IndexedDB) would each be **new** hand-written glue — but the
ABI substrate (sync `(ptr,len)`, async table-callback) is proven enough that it
would work.

---

## Bottom line

| Question | Answer |
| --- | --- |
| Can a **vcsr component** use all these resources today? | **No** — blocked at Gate 1 (runtime uses closures that trap on wasm), Gate 2 (no async substrate). Gate 3 (sync loader/substrate) is **done**. |
| Is the **mechanism** for each proven? | `fetch`, `localStorage`, `console`, DOM events: **yes** (hand-written). `crypto`, `URL`, `location`, timers/rAF, sockets, IndexedDB: **no / not demonstrated**. And compiled-V→wasm reactivity + `(ptr,len)` FFI: **yes**, closure-free ([examples/wasm-reactive/](examples/wasm-reactive/)). |
| Is there a working **all-eight** example anywhere? | **No.** The richest fixture (dashboard) covers ~4 (DOM, localStorage, fetch, log) in hand-written C. |
| Shortest path to "yes"? | Gate 3 ✅ → refactor `signal.v`/`runtime` closure-free (Gate 1, path proven) + wasm DOM backend → async dispatcher (Gate 2). |
