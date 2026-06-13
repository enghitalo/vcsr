# vcsr — a high-performance CSR compiler for V

> **Status: implementation in progress (TDD).** Phases 01–03 are **implemented
> and passing** — the `.html` parser ([`ast/`](ast), [`parser/`](parser)), slot
> extraction ([`slots/`](slots)), and reactive binding ([`bind/`](bind)). Phases
> 04–10 remain spec-first: their `tests/` files describe the behavior each phase
> must satisfy before the code lands.

`vcsr` compiles V UI components into a **fully client-side rendered (CSR)**
bundle that paints and updates entirely in the browser — no server round-trip to
mutate the DOM — and that is designed to be **served by
[vanilla](https://github.com/enghitalo/vanilla)**, the high-performance V HTTP
server.

It rests on three design ideas (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/DESIGN.md](docs/DESIGN.md)):

- **Standalone compiler — no V changes.** vcsr never modifies the V compiler.
  It is a source generator with its own `.html`/`.css` parsers that emits **plain
  V**, which the stock `v` then compiles to WASM. (So there are no `$vui`/`$css`
  comptime builtins — those would require forking V.)
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
 │ 7 wasm       stock `v -b wasm`: core MAIN + sides  (phase 07)  │
 │ 8 bundle     dist/ + hashing + brotli + sourcemaps (phase 08)  │
 │ 9 manifest   build record + dist/ for static_assets (phase 09) │
 │10 optimize   wasm-opt, prefetch hints, e2e         (phase 10)  │
 └──────────────────────────────────────────────────────────────┘
        │
        ▼
  dist/  ──────────────▶  served by vanilla's http_server.static_assets
```

Steps 1–5 are pure vcsr (parsers + codegen → plain V). Step 7 shells out to an
**unmodified** `v`. vcsr never patches the V compiler — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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

## CLI (planned)

```sh
vcsr build  ./src --out dist --release   # full production bundle
vcsr watch  ./src                        # dev server (HMR, source maps)
vcsr check  ./src                        # type/template diagnostics only
vcsr serve  dist                         # reference vanilla server over the bundle
```

## Examples

See [examples/](examples) for illustrative apps (source-only until the compiler
lands):

- [examples/counter](examples/counter) — the minimum: one component, signals, a
  computed value, scoped CSS.
- [examples/spa](examples/spa) — full feature set: router + code splitting (a
  lazy route), a shared component hoisted to core, a global store, two-way
  binding, list rendering, async fetch.
- [examples/serve-with-vanilla](examples/serve-with-vanilla) — serving a built
  `dist/` bundle with the vanilla HTTP server.

## Serving it with vanilla

`vcsr build` emits a `dist/` bundle; vanilla's `http_server.static_assets` serves
it. The whole handler is two lines — `static_assets.new` reads the bundle once at
boot, precomputes a response for every asset, and shares it lock-free across
workers:

```v
import http_server
import http_server.static_assets

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

Development is split into ten phases; each has a spec file under `tests/`. A
phase is "done" when its file's assertions hold against the implementation.

| Phase | File | Goal |
|---|---|---|
| 01 ✅ | [phase_01_template_parser_test.v](tests/phase_01_template_parser_test.v) | parse a `.html` template file → AST (interpolation, events, directives) — **implemented** ([ast/](ast), [parser/](parser)) |
| 02 ✅ | [phase_02_slot_extraction_test.v](tests/phase_02_slot_extraction_test.v) | AST → static skeleton + slot table — **implemented** ([slots/](slots)) |
| 03 ✅ | [phase_03_reactive_binding_test.v](tests/phase_03_reactive_binding_test.v) | slots → fine-grained signal bindings — **implemented** ([bind/](bind)) |
| 04 | [phase_04_component_model_test.v](tests/phase_04_component_model_test.v) | pair `.v`/`.html`/`.css`, resolve refs, **emit plain V** (no builtins) |
| 05 | [phase_05_scoped_css_test.v](tests/phase_05_scoped_css_test.v) | parse a `.css` file → scope + atomize + tree-shake |
| 06 | [phase_06_router_codesplit_test.v](tests/phase_06_router_codesplit_test.v) | route table → core/lazy chunk plan |
| 07 | [phase_07_wasm_linking_test.v](tests/phase_07_wasm_linking_test.v) | core MAIN + side modules over shared memory |
| 08 | [phase_08_bundle_emit_test.v](tests/phase_08_bundle_emit_test.v) | dist/ emission, hashing, brotli, sourcemaps |
| 09 | [phase_09_vanilla_manifest_test.v](tests/phase_09_vanilla_manifest_test.v) | manifest + a `static_assets`-consumable `dist/` (vanilla serves it) |
| 10 | [phase_10_e2e_test.v](tests/phase_10_e2e_test.v) | optimization passes + full build → servable bundle |

### Building & testing

The library modules (`ast`, `parser`) are plain V under the `vcsr` module name.
To resolve `import vcsr.parser` / `import vcsr.ast`, put the repo on V's module
path (clone it as `vcsr/`, or symlink it), then run the implemented phase:

```sh
ln -s "$PWD" ~/.vmodules/vcsr            # make `import vcsr.*` resolve
v test tests/phase_01_template_parser_test.v   # phase 01 — passes
```

Phases 02–10 import not-yet-built modules (`vcsr.slots`, …), so `v test tests/`
as a whole won't pass until those land — run the implemented phase file(s)
individually.

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
