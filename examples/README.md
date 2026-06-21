# vcsr examples

> **Status.** The compiler *internals* — phases 01–11 — are implemented and
> green (parser, slot extraction, reactive binding, the component model + plain-V
> codegen, scoped CSS, the router/chunk plan, the wasm link plan + ABI inspector,
> bundle/manifest/e2e). What's **not** built yet is the `vcsr` CLI binary and the
> runtime library (`vcsr` / `vcsr.runtime` — the `js` FFI substrate + signals)
> these apps import, plus browser-wasm *emission* (V can't emit browser wasm yet
> — see [docs/WASM-PATHS-ANALYSIS.md](../docs/WASM-PATHS-ANALYSIS.md)). So these
> remain the **authoring-experience** reference — except [counter](counter),
> which now runs through the real pipeline (see its README for the actual
> generated output). The rendering model is proven live in a browser by
> [tools/browser-smoke](../tools/browser-smoke).

The `vcsr` CLI exists ([cmd/vcsr](../cmd/vcsr)) with `gen` / `build` / `serve`.
Note: **`vcsr build` needs a browser `core.wasm`, which V can't emit from these
`.v` components yet** — so the example apps here are *not* `vcsr build`-able (they
ship no `build/`+`app.json`). What runs on them today is per-component codegen:

```sh
vcsr gen counter/src/counter             # → counter/src/counter.gen.v (plain V view()/style())
# A full, bundleable app (prebuilt browser-ABI wasm) lives in ../testdata; e.g.:
vcsr build ../testdata/dashboard-app && vcsr serve ../testdata/dashboard-app/dist
```

`vcsr watch` (HMR dev server) is still on the roadmap.

## Examples

| Example | Demonstrates |
|---|---|
| [counter](counter) | the minimum: one component, signals, a computed value, an event, scoped CSS — rendered 100% client-side into an empty page |
| [spa](spa) | the full feature set: router + code splitting (a lazy route), a shared component hoisted to core, a global store, two-way binding, list rendering, async data fetch |
| [serve-with-vanilla](serve-with-vanilla) | serving a built `dist/` bundle with the [vanilla](https://github.com/enghitalo/vanilla) HTTP server via `http_server.static_assets` |

## The shape of every app

A component is a **file triplet** sharing a basename (see
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)):

- `name.v` — logic: a `@[component]` struct (embedding `vcsr.Component`), its
  signal fields, event handlers, computed methods, and lifecycle hooks like
  `on_mount()`. **No `view()`/`style()`** — vcsr generates those.
- `name.html` — the template, in vcsr's dialect: `{{ expr }}`, `@click="handler"`,
  `@bind="signal"`, `@if`/`@for`/`:key`, `class:x`, `<Child :prop="…" />`.
  Identifiers resolve in the component's scope.
- `name.css` — plain CSS, scoped to the component at build time.

vcsr parses the `.html`/`.css` (its own parsers — **no V compiler changes, no
`$vui`/`$css`**) and emits `name.gen.v` (plain V implementing `view()`/`style()`),
which stock `v` compiles. Reactivity is `signal` / `computed` / `effect`: a write
updates only the slot nodes that read it.

See [docs/DESIGN.md](../docs/DESIGN.md) for why this is the high-performance path.
