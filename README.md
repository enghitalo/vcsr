# vcsr — a high-performance CSR compiler for V

> **Status: all 11 phases implemented and passing (TDD).** `v test tests/` is
> green end-to-end: the `.html` parser ([`ast/`](ast), [`parser/`](parser)), slot
> extraction ([`slots/`](slots)), reactive binding ([`bind/`](bind)), the
> component model ([`component/`](component)), scoped/atomized CSS ([`css/`](css)),
> the router + code-split plan ([`router/`](router)), the wasm link plan + ABI
> inspector ([`wasm/`](wasm)), the manifest reader ([`manifest/`](manifest)), and
> the bundle/e2e build ([`bundle/`](bundle)) serving through vanilla's
> `http_server.static_assets`.
>
> One honest caveat: V cannot yet compile a browser-ready wasm module (native
> `-b wasm -os browser` panics; `v -cc clang` emits WASI imports — see
> [docs/WASM-PATHS-ANALYSIS.md](docs/WASM-PATHS-ANALYSIS.md) and the upstream
> issues it filed). So the bundle's wasm step consumes **prebuilt browser-ABI
> wasm** fixtures; everything else (hashing, compression, manifest, linking,
> dead-route elimination, serving) is real.

`vcsr` compiles V UI components into a **fully client-side rendered (CSR)**
bundle that paints and updates entirely in the browser — no server round-trip to
mutate the DOM — and that is designed to be **served by
[vanilla](https://github.com/enghitalo/vanilla)**, the high-performance V HTTP
server.

It rests on three design ideas (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/DESIGN.md](docs/DESIGN.md)):

- **Standalone compiler — no V changes.** vcsr never modifies the V compiler.
  It is a source generator with its own `.html`/`.css` parsers that emits **plain
  V**, which the stock `v` then compiles to WASM — today via `v -cc clang` + the
  WASI SDK (see [docs/WASM-ABI.md](docs/WASM-ABI.md)), since V's native `-b wasm`
  backend can't yet compile the runtime. (So there are no `$vui`/`$css` comptime
  builtins — those would require forking V.)
- **A minimal `js` FFI substrate** — the irreducible host-call layer the
  generated code targets: hold a host reference and `get`/`set`/`call`/`new` on
  it (the WASM equivalent of "JS can touch the DOM"). DOM bindings, reactivity,
  and components are all plain-V libraries on top.
- **An embedded-HTML, clone-and-patch rendering model** — templates are compiled
  to a static HTML skeleton (embedded in the WASM data segment) plus a slot
  table, registered once as a native `<template>`, cloned per instance, and
  patched surgically by fine-grained signals (no Virtual DOM).

### Components are a file triplet (no inline magic strings)

A component is up to three co-located files sharing a basename — logic, template,
styles in **separate files**, parsed by vcsr:

```
counter/
├── counter.v      # @[component] struct + signals + handlers (logic only)
├── counter.html   # the template: {{ count }}, @click="inc", @for/@if/@bind …
└── counter.css    # scoped styles
```

vcsr pairs them, resolves the template's references against the struct, and
generates `counter.gen.v` (plain V implementing `view()`/`style()`). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and
[docs/COMPONENTS.md](docs/COMPONENTS.md) for the component model — PascalCase
references, props/events, and the inline-vs-boundary composition strategy.

## Why pair a CSR compiler with vanilla?

`vanilla` is a lock-free, copy-free, `SO_REUSEPORT`, epoll/io_uring server. A CSR
bundle is the *ideal* payload for it: a handful of **static, content-hashed,
precompressed** files (`index.html`, `app.js`, `*.wasm`, `app.css`). There is no
per-request server rendering — the server's job is to ship immutable bytes as
fast as the kernel allows (ETag, `sendfile`, brotli), which is exactly what
vanilla is built for. `vcsr` emits that `dist/`; vanilla's
`http_server.static_assets` serves it with the correct `Content-Type`,
`Content-Encoding`, `Cache-Control`, and SPA-fallback behavior — derived from the
filenames, so vanilla never has to render anything per request.

> Serving a CSR/WASM bundle needs a few things a bare file server doesn't
> (notably `application/wasm`, precompressed-asset negotiation, immutable caching,
> and SPA fallback). vanilla now ships exactly that as `http_server.static_assets`
> ([issue #19](https://github.com/enghitalo/vanilla/issues/19), implemented in
> [50df944](https://github.com/enghitalo/vanilla/commit/50df94495be7bad95dc5cbc6e6be7fe53dd7fcb7)),
> so vcsr just emits a `dist/` it serves — see
> [docs/VANILLA-STATIC-ASSETS.md](docs/VANILLA-STATIC-ASSETS.md).

## The performance thesis (what makes it fast)

| Decision | Why it's the fast path |
|---|---|
| **Embedded HTML in the WASM data segment** | the browser's native parser builds each subtree in one call; no `createElement`-per-node FFI |
| **`<template>` registered once + `cloneNode`** | per-instance render is a native clone, not N boundary crossings |
| **Fine-grained signals, no Virtual DOM** | a write updates only the exact slot nodes that read it — O(dependents), no diff |
| **`externref` DOM handles** | DOM nodes cross the boundary as host handles, never serialized through linear memory |
| **Core + per-route chunks over shared memory** | first load = core + landing route only; routes arrive just-in-time |
| **Static, hashed, brotli'd output** | vanilla serves immutable bytes with `sendfile`/ETag; nothing is rendered per request |

See [docs/DESIGN.md](docs/DESIGN.md) for the rendering mechanism and the
shared-memory code-splitting that keeps first load small.

## Compiler pipeline

```
  component triplet:  name.v (logic) + name.html (template) + name.css (styles)
        │
        ▼
 ┌──────────────────────────────────────────────────────────────┐
 │ 1 parse      .html template → AST                  (phase 01)  │
 │ 2 slots      AST → static HTML skeleton + slot table (phase 02)│
 │ 3 bind       slots → reactive binding code         (phase 03)  │
 │ 4 component  pair .v/.html/.css, resolve refs,                 │
 │              EMIT PLAIN V (name.gen.v)             (phase 04)  │
 │ 5 css        parse .css → scope + atomize + shake  (phase 05)  │
 │ 6 router     route table → chunk plan (core/lazy)  (phase 06)  │
 │ 7 wasm       v -cc clang(wasi): core MAIN + sides  (phase 07)  │
 │ 8 bundle     dist/ + hashing + brotli + sourcemaps (phase 08)  │
 │ 9 manifest   build record + dist/ for static_assets (phase 09) │
 │10 optimize   wasm-opt, prefetch hints, e2e         (phase 10)  │
 └──────────────────────────────────────────────────────────────┘
        │
        ▼
  dist/  ──────────────▶  served by vanilla's http_server.static_assets
```

Steps 1–5 are pure vcsr (parsers + codegen → plain V). Step 7 shells out to an
**unmodified** `v` — today `v -cc clang` feeding the WASI SDK, because V's native
`-b wasm` backend can't yet compile the runtime (it still errors on dynamic
arrays). vcsr never patches the V compiler — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and
[docs/WASM-ABI.md](docs/WASM-ABI.md) for the language-neutral module contract
this step targets. The three V→WASM routes (native `-b wasm`, V→clang, pure
clang) are measured feature-by-feature against the browser baseline in
[docs/WASM-PATHS-ANALYSIS.md](docs/WASM-PATHS-ANALYSIS.md).

## Output layout (`dist/`)

```
dist/
├── index.html              empty <body>; loads app.js (the WASM builds the UI)
├── app.[hash].js           tiny loader: streaming-instantiate + router + dynamic linker
├── core.[hash].wasm        runtime + reactive + dom + router + shared components + landing route
├── route-<name>.[hash].wasm one per lazy route; imports core's memory/table
├── app.[hash].css          scoped + atomized stylesheet
├── *.br / *.gz             precompressed siblings of each text/wasm asset
├── *.map                   source maps back to .v
└── manifest.json           vcsr's build record: { hash, route?, preload } — drives the loader
```

Every asset except `index.html` is content-hashed; `index.html` is tiny and
unhashed, so deploys flip atomically by swapping it. vanilla's `static_assets`
derives `Content-Type`/`Cache-Control`/encoding from the filenames + the
`*.[hash].*` glob (immutable for hashed assets, `no-cache` for `index.html`) — it
does not read `manifest.json`, which is vcsr's own record for the JS loader.

## CLI

[cmd/vcsr](cmd/vcsr) wires the implemented pipeline into commands:

```sh
vcsr gen   <triplet>          # analyze a .v/.html/.css triplet → write <name>.gen.v  (runs today)
vcsr build <app> [--release]  # bundle an app dir (with app.json + prebuilt build/*.wasm) → <app>/dist
vcsr serve <dist> [--port N]  # serve a built dist/ with the vanilla HTTP server
```

`build` requires a prebuilt browser-ABI `core.wasm` (V can't emit browser wasm
yet), so it targets apps like [testdata/dashboard-app](testdata/dashboard-app);
the dialect-source [examples](examples) use `vcsr gen` per component. `watch`
(HMR) and `check` remain on the roadmap. See [cmd/vcsr/README.md](cmd/vcsr/README.md).

## Examples

See [examples/](examples) for the authoring-experience reference. The compiler
internals (phases 01–11) are implemented; the `vcsr` CLI and runtime library
these apps import are the remaining roadmap.

- [examples/counter](examples/counter) — the minimum: one component, signals, a
  computed value, scoped CSS. **Runs through the real pipeline** — its README
  shows the actual `counter.gen.v` vcsr emits.
- [examples/spa](examples/spa) — the target-dialect illustration: router + code
  splitting (a lazy route), a shared component hoisted to core, a global store,
  two-way binding, list rendering, async fetch.
- [examples/serve-with-vanilla](examples/serve-with-vanilla) — serving a built
  `dist/` bundle with the vanilla HTTP server.

For a complex app **running live in a browser** (compiled C→wasm on vcsr's DOM
runtime), see [testdata/dashboard-app](testdata/dashboard-app) +
[tools/browser-smoke](tools/browser-smoke).

## Serving it with vanilla

`vcsr build` emits a `dist/` bundle; vanilla's `http_server.static_assets` serves
it. The whole handler is two lines — `static_assets.new` reads the bundle once at
boot, precomputes a response for every asset, and shares it lock-free across
workers:

```v
import vanilla.http_server
import vanilla.http_server.static_assets

// Built once at boot from the dist/ vcsr emitted; immutable afterwards.
const assets = static_assets.new(static_assets.Config{
	root: 'dist'
	// defaults: spa_fallback = 'index.html', immutable_glob = '*.[hash].*',
	//           precompressed = [.br, .gz], sendfile_min_bytes = 256 KiB
}) or { panic(err) }

fn handle(req []u8, _ int, mut out []u8) ! {
	// resolves path → asset, negotiates Accept-Encoding, sets application/wasm +
	// immutable Cache-Control, falls back to index.html for client routes.
	// respond_into uses zero-copy sendfile(2) for large bodies (respond() is the
	// pure-bytes API).
	assets.respond_into(req, mut out)!
}
```

What `static_assets` guarantees (and what vcsr's `dist/` is built to satisfy):

- `*.wasm` → `Content-Type: application/wasm` (**required** for
  `WebAssembly.instantiateStreaming`).
- `Accept-Encoding: br` / `gzip` → serve the precompressed sibling with
  `Content-Encoding` + `Vary: Accept-Encoding`.
- hashed assets (`*.[hash].*`) → `Cache-Control: public, max-age=31536000,
  immutable`; unhashed `index.html` → `Cache-Control: no-cache`.
- unknown, non-asset path (a client route like `/users/42`) → serve
  `index.html` so deep links and refreshes work (SPA fallback); asset-looking
  404s stay 404.
- ETag/304, Range/206, HEAD, and `../` path-traversal refusal are built in.

vcsr's only job here is emitting filenames + `.br`/`.gz` siblings the module
expects; the integration is documented in
[docs/VANILLA-STATIC-ASSETS.md](docs/VANILLA-STATIC-ASSETS.md).

## Development roadmap & tests

Development is split into ten pipeline phases plus a cross-cutting
ABI-conformance spec (phase 11); each has a spec file under `tests/`. A phase is
"done" when its file's assertions hold against the implementation.

| Phase | File | Goal |
|---|---|---|
| 01 ✅ | [phase_01_template_parser_test.v](tests/phase_01_template_parser_test.v) | parse a `.html` template file → AST (interpolation, events, directives) — **implemented** ([ast/](ast), [parser/](parser)) |
| 02 ✅ | [phase_02_slot_extraction_test.v](tests/phase_02_slot_extraction_test.v) | AST → static skeleton + slot table — **implemented** ([slots/](slots)) |
| 03 ✅ | [phase_03_reactive_binding_test.v](tests/phase_03_reactive_binding_test.v) | slots → fine-grained signal bindings — **implemented** ([bind/](bind)) |
| 04 ✅ | [phase_04_component_model_test.v](tests/phase_04_component_model_test.v) | pair `.v`/`.html`/`.css`, resolve refs, **emit plain V** (no builtins) — **implemented** ([component/](component)) |
| 05 ✅ | [phase_05_scoped_css_test.v](tests/phase_05_scoped_css_test.v) | parse a `.css` file → scope + atomize + tree-shake — **implemented** ([css/](css)) |
| 06 ✅ | [phase_06_router_codesplit_test.v](tests/phase_06_router_codesplit_test.v) | route table → core/lazy chunk plan — **implemented** ([router/](router)) |
| 07 ✅ | [phase_07_wasm_linking_test.v](tests/phase_07_wasm_linking_test.v) | core MAIN + side modules over shared memory — **implemented** ([wasm/](wasm)) |
| 08 ✅ | [phase_08_bundle_emit_test.v](tests/phase_08_bundle_emit_test.v) | dist/ emission, hashing, brotli, sourcemaps — **implemented** ([bundle/](bundle)) |
| 09 ✅ | [phase_09_vanilla_manifest_test.v](tests/phase_09_vanilla_manifest_test.v) | manifest + a `static_assets`-consumable `dist/` (vanilla serves it) — **implemented** ([manifest/](manifest)) |
| 10 ✅ | [phase_10_e2e_test.v](tests/phase_10_e2e_test.v) | optimization passes + full build → servable bundle (served by vanilla) — **implemented** ([bundle/](bundle)) |
| 11 ✅ | [phase_11_abi_conformance_test.v](tests/phase_11_abi_conformance_test.v) | the WASM ABI is **language-neutral**: a non-V module (Rust/Zig/C/WAT) honoring the contract conforms — **implemented** ([wasm/](wasm)), [docs/WASM-ABI.md](docs/WASM-ABI.md), fixtures in [tests/fixtures/abi/](tests/fixtures/abi) |
| 12 🚧 | [phase_12](tests/phase_12_runtime_signals_test.v) · [phase_13](tests/phase_13_runtime_ffi_test.v) · [phase_14](tests/phase_14_runtime_engine_test.v) | the **runtime library** the generated code imports — **in progress**. Slice 1 (reactive core: `Signal`/`effect` with dynamic dependency tracking + disposal, [signal.v](signal.v)) ✅, slice 2 (`js` FFI substrate: `JsValue` get/set/call/new + a mock host, [js_ffi.v](js_ffi.v)) ✅, and slice 3 (Template/bind engine: `instance()` clones the skeleton → `bind_*` wires each slot to a reactive effect → `View`, [runtime/runtime.v](runtime/runtime.v)) ✅ are done; the app/router runtime is next. This closes the loop from a triplet to a running app. |

### Building & testing

All modules (`ast`, `parser`, `slots`, `bind`, `component`, `css`, `router`,
`wasm`, `manifest`, `bundle`) are plain V under the `vcsr` module name. To
resolve `import vcsr.*`, put the repo on V's module path (clone it as `vcsr/`,
or symlink it). Phase 10 also serves through vanilla, so the `vanilla` module
must be on the path too (`v install` it, or symlink it as `vanilla`):

```sh
ln -s "$PWD" ~/.vmodules/vcsr                          # make `import vcsr.*` resolve
ln -s /path/to/vanilla ~/.vmodules/vanilla             # for phase 10 (vanilla.http_server.static_assets)
v -enable-globals test tests/                          # all 12 phases — pass
```

`-enable-globals` is needed because the runtime's reactive core (phase 12) keeps
its effect stack in a global — natural for the single-threaded wasm guest it
targets. Phases 01–11 don't need it; the whole suite runs fine with it on.

The whole suite is green. Two things the bundle phases rely on: `node` (for
brotli — V has no brotli) and the prebuilt browser-ABI `.wasm` under
`testdata/*/build/` (committed **inputs**, authored with clang/wat2wasm; V can't
yet emit browser wasm — see the status note above). The bundled `dist/` is
vcsr-generated output and is **not** committed — the tests regenerate it (phase
09 builds it in `testsuite_begin`; 08/10 build it directly).

### Real-browser validation

Beyond the socket-free phase-10 contract, [tools/browser-smoke/](tools/browser-smoke)
loads a built `dist/` in a real headless Chrome (Playwright) and asserts the wasm
instantiates, mounts, and renders. Two apps:

- `testdata/fixture-app` — the minimal bundle (18 checks).
- `testdata/dashboard-app` — **"vcsr console"**, a complex C→wasm32 app on the
  integer-handle DOM runtime: reactive state, events, computed values, list
  rendering, async `fetch`, `localStorage`-persisted theme, conditional views,
  and theming — exercised with real clicks/typing (14 checks; screenshots
  committed).

```sh
cd tools/browser-smoke && npm install
node browser-smoke.mjs        # fixture-app
node dashboard-smoke.mjs      # dashboard-app
```

## Contributing & engineering guidelines

vcsr is V code; a compiler is a hot loop over bytes. Two guides codify how to
keep it fast, correct, and free of V-compiler dependencies:

- [docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md) — passes as pure functions,
  emit plain V (no `$`-builtins), zero-copy over the source, deterministic
  output, injection-safe codegen, per-phase testing.
- [docs/V_PERF_TOOLBOX.md](docs/V_PERF_TOOLBOX.md) — reading emitted C, V
  attributes, array flags, allocation facts, and codegen string building.

## Non-goals

- **SSR / hydration** — that's a complementary, separate direction. `vcsr` is
  CSR-first (optionally prerender the landing route only).
- **Being a server** — that's `vanilla`. `vcsr` emits bytes; vanilla serves them.

## License

MIT (concept).
