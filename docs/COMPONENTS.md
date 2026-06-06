# Components

How components are declared, referenced, composed, and compiled in vcsr — and
the performance reasoning behind the composition strategy. Read alongside
[ARCHITECTURE.md](ARCHITECTURE.md) (the file-triplet + plain-V codegen) and
[DESIGN.md](DESIGN.md) (the clone-and-patch render model).

> Status: design. Phase 01 (parser) and phase 02 (slots) are implemented; the
> component model below is what **phase 04** (component) and **phase 06**
> (router/splitting) will encode. Code samples are illustrative.

## 1. A component is a file triplet

A component is a `@[component]` struct plus its co-located template and styles,
sharing a basename:

```
counter/
├── counter.v      # logic: the struct, signal fields, handlers, lifecycle hooks
├── counter.html   # template (vcsr dialect)
└── counter.css    # scoped styles (optional)
```

`counter.v` holds **only logic** — vcsr generates `view()`/`style()` into
`counter.gen.v`. See [ARCHITECTURE.md](ARCHITECTURE.md).

## 2. Referencing a component: PascalCase = the struct name

A component is used in a template by a **PascalCase tag equal to its struct
name** — a 1:1 mapping, no prefix or kebab-case transform to remember:

```html
<!-- home.html -->
<main>
  <Button label="+1" @click="inc" />
  <UserCard :user="current" />
</main>
```

`<Button>` ↔ `struct Button`, `<UserCard>` ↔ `struct UserCard`. This matches
JSX/Vue/Svelte and keeps the source readable: the tag literally names the type.

The parser distinguishes a component from a built-in element by the
**leading-uppercase rule** (`parser.is_component_name`): `<Button>` →
`NodeKind.component`, `<button>` → `NodeKind.element`.

### The invariant that makes PascalCase safe

HTML is case-insensitive: a browser's HTML parser lowercases tag names, so
`<Button>` would become `<button>` (a real element — a silent collision). vcsr
avoids this by a hard rule:

> **A component tag is resolved at compile time and never appears in the static
> skeleton handed to the browser's `<template>` parser.**

Codegen either **inlines** the child or replaces it with a **mount anchor**
(below). A phase-04 test asserts that no component tag survives in
`CompiledTemplate.html`. Because the browser never sees `<Button>`, the
case-folding footgun cannot fire.

## 3. Props and events

| In the template | Meaning | Cost |
|---|---|---|
| `label="+1"` | **static** prop (string literal) | set once; zero ongoing cost |
| `:label="name"` | **bound** prop (reactive expression) | updates when `name` changes |
| `@click="inc"` | event → a handler passed to the child | one listener bind |

Props resolve in the **parent's** scope (`name`, `inc` are the parent struct's
fields/methods). Props are type-checked against the child struct's fields at
build time; an unknown or wrongly-typed prop is a compile error (phase 04).

## 4. Composition strategy: inline by default, boundary on demand

This is the performance-critical decision. With fine-grained signals there is
**no re-render** — every update is `O(slots that changed)` regardless of how
components compose. So composition choice does **not** affect update cost; it
affects **creation cost** (host/FFI crossings) and **binary size**. Two modes:

### Inline (vanishing components) — the default

The child's compiled template is **merged into the parent's skeleton** at build
time (its slot paths offset into the parent tree). The whole parent+children
subtree is **one `<template>`, one `cloneNode`**, and props become ordinary
slots. The component boundary disappears at runtime.

- ✅ Fewest clones and FFI crossings; props are direct slots.
- ⚠️ Duplicates the child's markup wherever it's inlined (bigger data segment;
  brotli mitigates, but startup parse grows).

### Boundary (register-once template + `mount`) — on demand

The child keeps its own registered `<template>`; the parent's generated `view()`
calls `child.mount(node)` at a placeholder, and `child.unmount()` on teardown.

- ✅ One template per component (smaller binary); enables dedup, code-splitting,
  dynamism, and per-item cloning for lists.
- ⚠️ One extra clone + a `mount` call + slot re-resolution per instance.

### The rule

**Inline by default. Emit a boundary when any of these holds:**

| Trigger | Why a boundary is required |
|---|---|
| used inside a `@for` list | clone the row template once per item — inlining N copies would explode the data segment |
| **shared / hoisted to core** (used by ≥ N routes) | one copy in `core.wasm`, reused across chunks — dedup + cross-chunk reuse |
| **lazy / in another chunk** (a route's component) | the child lives in a different `.wasm`; you can only reach it via `mount` over shared memory |
| **dynamic** (`<component :is="expr">`) or **recursive** | the concrete child isn't known at compile time / can't be inlined infinitely |

The "shared/hoisted" trigger reuses the **same usage count** phase 04 already
computes for `decide_hoist` — a rare, one-off child inlines; a frequently-used
or route-shared child becomes a boundary in core. So `decide_hoist` and
`decide_inline_vs_boundary` are the same signal viewed two ways.

## 5. Cost model (why the rule is what it is)

Creation cost ≈ number of WASM↔host crossings:

```
creation ≈ (#cloneNode)  +  (#slot-node navigations)  +  (#initial binds)
```

- **Inline** collapses `#cloneNode` to 1 for the whole subtree.
- **Boundary** does 1 clone per component instance.
- **Binds are the same either way** — each instance still attaches its own
  listeners / sets its own initial text/attrs. Inlining saves clones and `mount`
  calls, **not** binds.

Update cost is `O(changed slots)` in **both** modes (signals, no diff) — this is
the big win over a Virtual DOM (`O(tree) + diff` per update) or an
innerHTML re-render (re-parse, loses node identity/focus/state).

Ranking for the common case (static composition, fine-grained updates):

1. **Hybrid** (inline one-offs, boundary for list/shared/lazy/dynamic) — best
   creation cost without exploding size or breaking code-splitting.
2. Inline-only — fast, but bloats size and can't code-split.
3. Boundary-only — fine; pays extra clones/`mount` for one-off children.
4. Web Components — platform/shadow-DOM overhead.
5. Virtual DOM — per-update diffing.
6. innerHTML — re-parse, loses identity.

## 6. Lifecycle

A component struct may define hooks; the generated `view()`/`mount()` wires them:

| Hook | When |
|---|---|
| `on_mount()` | after the instance's nodes are in the document |
| `on_destroy()` | before its nodes are removed (route change, list item removed) |

Hooks run whether the component was inlined or mounted as a boundary — the
codegen schedules them; inlining doesn't drop them. `spawn` inside `on_mount`
runs on the browser event loop (see [DESIGN.md](DESIGN.md) §async).

## 7. What the generated code looks like

**Inlined child** — merged into the parent's single template; the `Button`'s
text/click become slots in the parent's table:

```v
// home.gen.v (sketch) — one template for <main> + the inlined <Button>
pub fn (mut h Home) view() vcsr.View {
	mut ins := __home_tpl.instance()          // one clone for the whole subtree
	runtime.bind_text(ins, 0, fn [h] () string { return h.count.get().str() })
	runtime.bind_event(ins, 1, h.inc)         // the Button's @click, inlined
	return ins.view()
}
```

**Boundary child** — `Button` is shared/hoisted, so it's mounted:

```v
// home.gen.v (sketch) — Button reached via a mount anchor
pub fn (mut h Home) view() vcsr.View {
	mut ins := __home_tpl.instance()
	mut btn := Button{ label: '+1', on_click: h.inc }  // props passed in
	btn.mount(ins.anchor(0))                            // child owns its clone
	return ins.view()
}
```

Both are **plain V importing only `vcsr.runtime`** — no `$`-builtins, no V
compiler changes (the cardinal rule, [ARCHITECTURE.md](ARCHITECTURE.md)).

## 8. Open questions (not yet specced)

- **Content projection / children** (`<Card>…children…</Card>`, named slots) —
  how a parent passes markup *into* a child. Likely a `<slot/>` placeholder in
  the child template; deferred until the base model lands.
- **Dynamic components** (`<component :is="expr">`) — always a boundary; needs a
  registry keyed by component name.
- **Recursion** (a component that transitively references itself) — must force a
  boundary to terminate inlining; the compiler detects cycles in the component
  graph.

These don't block phases 01–06; they're follow-ups once static composition works.
