# vcsr examples

Each example with a `src/entry_d_wasm_browser.v` builds to a browser
`core.wasm` and renders in a real browser:

```sh
vcsr wasm examples/<name>/src      # gen + compile → examples/<name>/wasm/
vcsr serve examples/<name>/wasm    # open http://localhost:3000
make examples                      # build all of them and check each in Chrome
```

| Example | Demonstrates | Renders |
|---|---|---|
| [counter](counter) | one component: a signal, a computed value, a click handler | ✅ in Chrome ([screenshot](counter/screenshot.png)) |
| [template-basics](template-basics) | the template language: mixed text, expressions in `{{ }}`, `@bind` on a void `<input>`, entities, whitespace | ✅ in Chrome ([screenshot](template-basics/screenshot.png)) |
| [serve-with-vanilla](serve-with-vanilla) | serving a built `dist/` with the [vanilla](https://github.com/enghitalo/vanilla) HTTP server via its `static_assets` module | ✅ (serves `testdata/fixture-app`) |
| [spa](spa) | the *target* authoring experience: router + code splitting, a shared component, a store, lists, async fetch | ❌ illustrative — uses features still on the [roadmap](../docs/ROADMAP.md) |

New examples land with the roadmap features they demonstrate, each with a
screenshot in its README taken by
[`tools/browser-smoke/example.mjs`](../tools/browser-smoke/example.mjs).

## The shape of every app

A component is a **file triplet** sharing a basename (see
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)):

- `name.v` — logic: a `@[component]` struct, its signal fields, event handlers
  and computed methods. **No `view()`/`style()`**: vcsr generates those.
- `name.html` — the template in vcsr's dialect. What works today is listed in
  [docs/REVIEW-2026-10.md](../docs/REVIEW-2026-10.md#what-renders-today).
- `name.css` — plain CSS.

vcsr parses the `.html`/`.css` with its own parsers (**no V compiler changes**)
and emits `name.gen.v`: plain V implementing `view()`/`style()`, which stock `v`
compiles. Reactivity is fine-grained signals: a write updates only the slot
nodes that read it.

An example's `wasm/` directory holds the committed page (`index.html`) and its
entry (`app.js`); `vcsr wasm` adds the generated `core.wasm` and `vcsr_host.js`
(the browser side of the DOM ABI, rewritten on every build).
