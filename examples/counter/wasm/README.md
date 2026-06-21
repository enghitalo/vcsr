# counter — compiled V → wasm, running in the browser

The vcsr **counter component** ([../src/](../src/)) compiled to a browser-ABI
`core.wasm` and running reactively against the real DOM. This is Gate 1 closed for
the counter: a V-authored component, through the implemented pipeline, executing in
a browser — not a hand-written fixture.

## How it works

- **`v -cc clang` + wasi-sdk** compiles the counter + the vcsr runtime to wasm
  ([build.sh](build.sh)), with **`-d wasm_browser`** selecting the runtime's
  **host-owned-DOM backend** ([../../../runtime/backend_wasm_d_wasm_browser.v](../../../runtime/backend_wasm_d_wasm_browser.v)).
- That backend is **closure-free and map-free** — both V capturing closures and
  V `map[string]` *validate but don't run* on wasm (see
  [WASM-PATHS-ANALYSIS.md §2.1](../../../docs/WASM-PATHS-ANALYSIS.md)). So the host
  parses the template and owns the DOM nodes (by integer handle); the V side keeps
  only the reactive logic (signals/effects) + FFI calls, using arrays/int-keys.
- [app.js](app.js) implements the DOM ABI ([vcsr_host.h](../../../runtime/vcsr_host.h))
  against `document` + a minimal WASI shim. `boot()` mounts; the rendered `+1`
  button's click is wired straight to the wasm `inc()` via `host_on` →
  `vcsr_dispatch`. A click writes the `count` signal; the subscribed slot effects
  re-patch **only** `<h1>` (count) and `<span>` (doubled) — no diff, no re-render.

## Run

```sh
WASI_SDK=/opt/wasi-sdk ./build.sh        # build core.wasm (gitignored artifact; needs wasi-sdk)
node smoke.mjs                            # headless proof in Node/V8 (Chrome's engine), after build
# in a browser: serve this dir and open index.html, e.g.
python3 -m http.server 8000              # then visit http://localhost:8000
```

`smoke.mjs` drives `core.wasm` against a faithful minimal DOM ([dom.mjs](dom.mjs))
and asserts the reactive loop:

```
after boot(): <main class="counter"><h1>0</h1>…<span>0</span>…<button>+1</button></main>
after click:  …<h1>1</h1>…<span>2</span>…
after x3:     …<h1>3</h1>…<span>6</span>…
✅ PASS — click runs inc(); the signal write re-patches the bound <h1>/<span> via host FFI.
```

The host ABI is identical to a browser's; only the DOM implementation differs
(Node/V8 is Chrome's engine). `instantiateStreaming` in [app.js](app.js) needs the
server to send `Content-Type: application/wasm`.

## What this does NOT cover yet

- The **App/Component** layer ([../../../runtime/app_notd_wasm_browser.v](../../../runtime/app_notd_wasm_browser.v))
  is native-only (it leans on the `js_ffi` mock, whose maps don't run on wasm); the
  wasm entry ([../src/entry_d_wasm_browser.v](../src/entry_d_wasm_browser.v)) drives
  the generated `view()` directly. A map-free wasm App + router is future work.
- Two-way `@bind` writeback is wired (`host_on_input` → `vcsr_dispatch_input`) but
  unexercised by the counter.
