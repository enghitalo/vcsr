# vcsr examples

> **Status: illustrative source.** The compiler is not implemented yet (see the
> repo [README](../README.md) and [docs/DESIGN.md](../docs/DESIGN.md)). These
> examples show the source a developer would write and the commands they would
> run; `vcsr build` does not exist yet. They double as the human-readable
> companion to the spec-first tests in [`../tests`](../tests).

Each example is a self-contained app. The intended workflow for all of them:

```sh
vcsr build  ./src --out dist --release   # emit the CSR bundle into dist/
vcsr watch  ./src                        # dev server with HMR + source maps
# then serve dist/ with vanilla — see examples/serve-with-vanilla
```

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
