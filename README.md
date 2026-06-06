# vcsr — a high-performance CSR compiler for V

> **Status: implementation in progress (TDD).** Phases 01–02 are **implemented
> and passing** — the `.html` parser ([`ast/`](ast), [`parser/`](parser)) and slot
> extraction ([`slots/`](slots)). Phases 03–10 remain spec-first: their `tests/`
> files describe the behavior each phase must satisfy before the code lands.

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
vanilla is built for. `vcsr` emits those bytes **plus a manifest** vanilla reads
to answer every request with correct `Content-Type`, `Content-Encoding`,
`Cache-Control`, and SPA-fallback behavior.

> Serving a CSR/WASM bundle needs a few things vanilla's `static_files` example
> doesn't cover yet (notably `application/wasm`, precompressed-asset negotiation,
> immutable caching, and SPA fallback). Those are written up as a concrete
> proposal in [docs/ISSUE-vanilla-static-assets.md](docs/ISSUE-vanilla-static-assets.md)
> to file upstream.

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
 │ 9 manifest   asset table for vanilla (mime/cache)  (phase 09)  │
 │10 optimize   wasm-opt, prefetch hints, e2e         (phase 10)  │
 └──────────────────────────────────────────────────────────────┘
        │
        ▼
  dist/  ──────────────▶  served by vanilla (static + manifest)
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
└── manifest.json           asset → { hash, content_type, encoding, cache, route? }
```

Every asset except `index.html` is content-hashed and immutable; `index.html`
is tiny and `no-cache`, so deploys flip atomically by swapping it.

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

`vcsr build` emits `dist/manifest.json`. A vanilla request handler reads it once
at boot and answers each request with the right headers — the response building
is pure logic (testable without a socket, exactly like vanilla's own
`static_files` tests):

```v
import http_server
import vcsr.serve { AssetServer }

// load the manifest produced by `vcsr build`
mut assets := AssetServer.load('dist/manifest.json')!

fn handle_request(req []u8, fd int) ![]u8 {
	// AssetServer resolves path → asset, negotiates Accept-Encoding (br/gzip),
	// sets application/wasm + immutable Cache-Control, and falls back to
	// index.html for client-side routes. Returns raw HTTP bytes for vanilla.
	return assets.respond(req)
}
```

What `AssetServer` guarantees (and what the phase-09 tests pin down):

- `*.wasm` → `Content-Type: application/wasm` (**required** for
  `WebAssembly.instantiateStreaming`).
- `Accept-Encoding: br` / `gzip` → serve the precompressed sibling with
  `Content-Encoding` + `Vary: Accept-Encoding`.
- hashed assets → `Cache-Control: public, max-age=31536000, immutable`;
  `index.html` → `Cache-Control: no-cache`.
- unknown, non-asset path (a client route like `/users/42`) → serve
  `index.html` so deep links and refreshes work (SPA fallback).
- ETag / `If-None-Match` and `Range` reuse vanilla's existing support.

The upstream gaps this relies on are proposed in
[docs/ISSUE-vanilla-static-assets.md](docs/ISSUE-vanilla-static-assets.md).

## Development roadmap & tests

Development is split into ten phases; each has a spec file under `tests/`. A
phase is "done" when its file's assertions hold against the implementation.

| Phase | File | Goal |
|---|---|---|
| 01 ✅ | [phase_01_template_parser_test.v](tests/phase_01_template_parser_test.v) | parse a `.html` template file → AST (interpolation, events, directives) — **implemented** ([ast/](ast), [parser/](parser)) |
| 02 ✅ | [phase_02_slot_extraction_test.v](tests/phase_02_slot_extraction_test.v) | AST → static skeleton + slot table — **implemented** ([slots/](slots)) |
| 03 | [phase_03_reactive_binding_test.v](tests/phase_03_reactive_binding_test.v) | slots → fine-grained signal bindings |
| 04 | [phase_04_component_model_test.v](tests/phase_04_component_model_test.v) | pair `.v`/`.html`/`.css`, resolve refs, **emit plain V** (no builtins) |
| 05 | [phase_05_scoped_css_test.v](tests/phase_05_scoped_css_test.v) | parse a `.css` file → scope + atomize + tree-shake |
| 06 | [phase_06_router_codesplit_test.v](tests/phase_06_router_codesplit_test.v) | route table → core/lazy chunk plan |
| 07 | [phase_07_wasm_linking_test.v](tests/phase_07_wasm_linking_test.v) | core MAIN + side modules over shared memory |
| 08 | [phase_08_bundle_emit_test.v](tests/phase_08_bundle_emit_test.v) | dist/ emission, hashing, brotli, sourcemaps |
| 09 | [phase_09_vanilla_manifest_test.v](tests/phase_09_vanilla_manifest_test.v) | manifest + vanilla response building |
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
