# Example: spa

A production-shaped single-page app exercising the full feature set, and the
code-splitting story from [docs/DESIGN.md](../../docs/DESIGN.md).

```sh
vcsr build ./src --out dist --release
# serve dist/ — see ../serve-with-vanilla
```

## What it demonstrates

| Feature | Where |
|---|---|
| Router + route params | [src/main.v](src/main.v) |
| **Code splitting** — a lazy route in its own WASM chunk | `/reports` (`lazy: true`) in [src/main.v](src/main.v) |
| **Shared component** hoisted into core (used by ≥2 routes) | [src/shared/button.v](src/shared/button.v) + [button.html](src/shared/button.html) |
| Signals + computed | [src/components/home.v](src/components/home.v) + [home.html](src/components/home.html) |
| Two-way binding + list/conditional render | [src/components/todos.html](src/components/todos.html) (+ [todos.v](src/components/todos.v)) |
| Async data fetch + loading/error + route param | [src/components/reports.v](src/components/reports.v) (+ [reports.html](src/components/reports.html)) |
| Global reactive store + theming | [src/store/store.v](src/store/store.v) |
| Design tokens + scoped component CSS | [src/styles/global.css](src/styles/global.css) + each component's `.css` |

Every component is a triplet (`*.v` logic + `*.html` template + `*.css` styles);
vcsr generates the `view()`/`style()` as plain V. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).

## How splitting plays out here

- `core.wasm` carries the runtime, the router, the **shared `Button`**, the
  global store, and the landing route (`Home`).
- `route-reports.wasm` is a separate chunk fetched on first navigation to
  `/reports`. It imports core's memory/runtime and **reuses** `Button` (one
  copy, in core) while carrying only its own page template.
- A signal created via core's runtime in `Reports` is the same machinery the
  rest of the app uses — reactivity crosses the core/chunk boundary because they
  share one heap and one runtime.

First load = `core.wasm` + `Home` only; `/reports` arrives just-in-time (and
sooner if prefetched on link hover).
