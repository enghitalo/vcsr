# vcsr roadmap

The implementation list that follows [REVIEW-2026-10.md](REVIEW-2026-10.md).
Each item lands as its own PR, verified with `make test`, a real wasm build and
a real-browser check. Items marked ★ make something new render; each of those
ships an example under `examples/` whose README shows a screenshot taken by
[`tools/browser-smoke/example.mjs`](../tools/browser-smoke/example.mjs).

## Milestone 1 — one honest pipeline

- [x] **1. One host loader + example runner** ★
  `runtime/vcsr_host.js` becomes the single, vcsr-owned implementation of the
  DOM ABI (rewritten on every `vcsr wasm`); the user's `app.js` shrinks to an
  import. Fix the unconditional `preventDefault()`. Retire the duplicate ABI
  copies (`examples/counter/wasm/app.js`, `dom.mjs`). Add the example runner
  and `make examples`. Counter README gets a screenshot.
- [x] **2. Template language correctness** ★ `examples/template-basics`
  Whitespace policy, `{{ }}`-aware text scanning, void elements, error on
  content after the root, attribute escaping, closing tags for self-closed
  non-void elements, line:col errors; text mixed with interpolations; one
  shared expression lexer for `free_idents` and `qualify`.
- [ ] **3. Styles end to end** ★ `examples/styling`
  One scoper (`css.scope`); codegen rewrites template class names; `style()`
  is injected once per component on wasm; harden the CSS tokenizer (comments,
  strings, `url()`, at-rules); stop `atomize` from reordering the cascade;
  `class:name` bindings.

## Milestone 2 — rendering features

- [ ] **4. `@if` / `@else`** ★ `examples/conditional`
  Anchor-based conditional rendering of the row sub-template, with its own
  slots bound while shown and disposed when hidden.
- [ ] **5. `@for` keyed lists** ★ `examples/todo`
  Rows cloned from the row sub-template per item of a `Signal[[]T]`, the loop
  variable (and index) in scope, rows reused by `:key`.
- [ ] **6. Events and forms** ★
  Modifiers (`.prevent`, `.stop`, key filters like `.enter`), event values,
  `@bind` for checkboxes, selects and numbers.
- [ ] **7. Child components** ★ `examples/components`
  `vcsr gen <dir>` over every triplet; boundary mount with static/bound props
  and events up to the parent; then inlining for one-off children.

## Milestone 3 — apps

- [ ] **8. `vcsr build` from V sources**
  The V→wasm recipe becomes a library call (`--release` honoured); `vcsr build`
  compiles `src/` triplets, generates the wasm entry, ships the one loader and
  an `index.html` with `#app`.
- [ ] **9. Client-side router** ★ `examples/router`
  Routes from `app.json` in one `core.wasm`; History API navigation, links,
  deep links.
- [ ] **10. Honest manifest and tests**
  Drop or relabel the modelled link plan / ABI checks; encode the manifest from
  a struct shared with the reader; tests look assets up instead of relying on
  hash-mined fixtures; `make test` builds and instantiates a real V module.

## Milestone 4 — quality

- [ ] **11. CI** — GitHub Actions: `make test`, examples built with wasi-sdk,
  browser checks in Chrome.
- [ ] **12. Docs** — README quickstart; one status/feature matrix; merge the
  overlapping docs; document the real host ABI; remove stale claims.
- [ ] **13. Size** — find where v3's ~205 KB counter goes; `-Oz` / `wasm-opt`
  for `--release`.
- [ ] **14. Upstream** — report the six V v3 issues from the review (with the
  minimal reproductions), once the maintainer OKs filing them.
