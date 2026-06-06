# Example: counter

The smallest meaningful vcsr app: a single component with a signal, a computed
value, a click handler, and scoped CSS. The page ships empty; the WASM builds
the UI client-side and patches only the text nodes that change.

```sh
vcsr build ./src --out dist --release
# serve dist/ — see ../serve-with-vanilla
```

Files:

- [src/main.v](src/main.v) — the `Counter` component and the app entrypoint.
- [index.html](index.html) — the empty shell; `vcsr build` emits the hashed,
  production version of this into `dist/`.

What to notice:

- `${c.count}` and `${doubled}` are the only dynamic holes. A click runs
  `inc`, which calls `count.set(...)`; only the two text nodes that read those
  signals update — no re-render, no diff.
- `doubled` is a `computed`: it recomputes only when `count` changes.
- `style()` is scoped to `Counter` at build time, so `.counter`/`.muted` can't
  collide with any other component.
