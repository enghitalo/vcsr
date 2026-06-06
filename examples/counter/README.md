# Example: counter

The smallest meaningful vcsr app: a single component as a **file triplet** — V
logic, an HTML template, and CSS in separate files. The page ships empty; the
WASM builds the UI client-side and patches only the text nodes that change.

```sh
vcsr build ./src --out dist --release
# serve dist/ — see ../serve-with-vanilla
```

Files:

- [src/counter.v](src/counter.v) — **logic**: the `Counter` struct, its `count`
  signal, the `inc` handler, and the `doubled` computed. No `view()`/`style()` —
  vcsr generates those.
- [src/counter.html](src/counter.html) — the **template** (vcsr's dialect).
- [src/counter.css](src/counter.css) — **scoped styles**.
- [src/main.v](src/main.v) — the app entrypoint (`new_app` → `render` → `mount`).
- [index.html](index.html) — the empty shell; `vcsr build` emits the hashed
  production version into `dist/`.

What to notice:

- `{{ count }}` and `{{ doubled }}` are the only dynamic holes; `@click="inc"`
  binds the handler. These identifiers resolve in the `Counter` struct's scope.
- A click runs `inc`, which calls `count.update(...)`; only the two text nodes
  that read those signals update — no re-render, no diff.
- vcsr scopes `counter.css` to `Counter` at build time, so `.counter`/`.muted`
  can't collide with any other component.
- vcsr generates `counter.gen.v` (plain V) implementing `view()`/`style()`;
  stock `v` compiles it. **No `$vui`/`$css`, no V compiler changes** — see
  [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
