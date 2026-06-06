# vcsr design

This is the self-contained design rationale for the compiler. It explains the
two foundations (the FFI substrate and the embedded-HTML render model), the
reactivity model, how code-splitting keeps first load small, and the contract
with the [vanilla](https://github.com/enghitalo/vanilla) HTTP server.

> Status: design + spec-first tests. The compiler is not implemented yet; the
> `tests/` folder is the executable specification of the behavior below.

## 1. The raw substrate: a tiny host-call FFI

WebAssembly is a guest: by default it can touch nothing in the page — no DOM, no
`fetch`, no `console`. So the one irreducible thing the toolchain must provide
(everything else can be a library) is a **host-call FFI**: hold a reference to a
host (JS) value and operate on it. It maps 1:1 to Go's `syscall/js.Value`:

```v
pub type JsValue = ...            // opaque handle, lowered to a wasm externref

pub fn global() JsValue
pub fn (v JsValue) get(prop string) JsValue
pub fn (v JsValue) set(prop string, val JsValue)
pub fn (v JsValue) call(method string, args ...JsValue) JsValue
pub fn (v JsValue) new(args ...JsValue) JsValue
pub fn func(f fn (this JsValue, args []JsValue) JsValue) JsValue // export a closure
// + string/number/bool conversions across the boundary
```

This is the WASM equivalent of "JavaScript can touch the DOM." DOM bindings,
`fetch`, reactivity, components, and templating are all **libraries** layered on
top — so frameworks can compete and evolve without a language release. (Precedent:
Rust's `wasm-bindgen` → `web-sys` → Yew/Leptos; Go's `syscall/js`.)

Because DOM nodes are `externref` handles, they cross the WASM↔host boundary
**without being serialized into linear memory** — no manual struct marshalling.

## 2. The render model: embedded HTML, clone-and-patch

Building the DOM node-by-node (`createElement`/`appendChild`) costs one
WASM↔host crossing per node — slow for large trees. The browser's native HTML
parser is far faster. So `vcsr` compiles each template into two parts:

1. **A static HTML skeleton** — the markup with dynamic content emptied out.
   This is a string constant, so it ends up **verbatim in the WASM binary's data
   segment** ("the HTML is embedded in the WASM").
2. **A slot table** — where the dynamic holes are (child-index path from the
   clone root), their kind (text/attr/event/bind/cond/list), and the driving
   expression.

For example, a `counter.html` template file (parsed by vcsr — **not** a V
compiler builtin; see [ARCHITECTURE.md](ARCHITECTURE.md)):

```html
<section class="counter"><h1>{{ count }}</h1><button @click="inc">+1</button></section>
```

lowers (in the generated `counter.gen.v`) to:

```v
const _tpl_html  = '<section class="counter"><h1></h1><button>+1</button></section>'
const _tpl_slots = [
    SlotDesc{ kind: .text,  path: [0] },               // <h1> text  <- count
    SlotDesc{ kind: .event, path: [1], name: 'click' },// <button>   <- inc
]
```

At runtime:

1. The skeleton string is handed to the host **once** to build a `<template>`
   (one FFI call; the native parser does the structural work).
2. Each instance is a single native `content.cloneNode(true)` — no per-node FFI.
3. The runtime walks to the slot nodes once (caching their `externref` handles)
   and binds them to signals.

So the only boundary crossings are: one parse, N clones, and one patch per
*changed* slot — instead of one per *node*.

This "register a static template once, clone it, patch only the holes" technique
is established (lit-html, Solid's compiled templates). The synthesis here is
doing it from WASM with the blueprints in the **data segment** and the holes
bound through **`externref`**, so a guest language drives a fully client-side UI
with near-zero marshalling.

## 3. Reactivity: fine-grained signals, no Virtual DOM

A `Signal[T]` is a value plus the set of effects that read it. Reading inside an
effect subscribes that effect; writing notifies exactly its subscribers.

```v
mut count := signal(0)
count.get()                 // read  → registers a dependency
count.set(5)                // write → notifies only the subscribed slots
doubled := computed(fn () int { return count.get() * 2 }) // memoized
```

A Virtual DOM recomputes and diffs a tree on every change — O(view size). Signals
build the dependency graph **at compile time** from the template, so a write
updates only the exact slot nodes that read it — O(dependents), no diff, no
per-frame allocation. There is no reconciler in the shipped binary.

## 4. Scaling: core + per-route chunks over shared memory

A single `app.wasm` holding dozens of routes is a slow first load (download +
up-front compile, plus every route's embedded HTML in the data segment). The fix
is code-splitting — which is trickier for WASM than JS because each module has
its own linear memory and function table by default.

**Architecture:**

```
core.wasm      MAIN module: runtime + reactive + dom + router + SHARED
               components + the landing route. Owns and EXPORTS the memory,
               the indirect function table, the allocator.
route-*.wasm   SIDE modules: one per lazy route, position-independent, IMPORT
               core's memory/table/runtime; carry only their own templates and
               route-local components; EXPORT mount()/unmount().
```

This is the Emscripten `MAIN_MODULE`/`SIDE_MODULE` + `dlopen` model. At load
time a small dynamic-linker stub assigns each chunk a free region of the shared
memory (`__memory_base`) and table (`__table_base`) and patches its GOT, so
chunks coexist in one memory without colliding, and a closure created in a chunk
lands in the shared table so core can call it. `externref` values (DOM nodes,
callbacks) need no relocation at all. The emerging Component Model / module
linking standard replaces the hand-written linker with a manifest.

**Why components aren't hurt by splitting:** a component used by ≥2 routes is
hoisted into core (one copy, one `<template>` registered once, cached); a
route-local component stays in its chunk. Because there is **one runtime and one
shared heap** in core, a signal created in core and read in a chunk is the same
object — reactivity crosses the boundary. The very thing that makes splitting
safe (shared memory + one runtime + shared component templates in core) is what
lets components survive it. Reuse and code-splitting reinforce each other.

**Keeping first load instant:** stream the compile (`instantiateStreaming`),
prefetch route chunks on intent (hover/viewport/idle), brotli-compress, and
content-hash for long-term caching. A 60-route app then loads like a 1-route
app; routes 2..60 arrive just-in-time.

## 5. The output, and the vanilla contract

`vcsr build` emits a static, content-hashed, precompressed bundle plus a
`manifest.json`. There is no per-request rendering — the server ships immutable
bytes, which is exactly what vanilla (lock-free, copy-free, `sendfile`, ETag) is
built for.

```
dist/
├── index.html              empty <body>; loads the hashed loader
├── app.[hash].js           streaming-instantiate loader + router + dynamic linker
├── core.[hash].wasm        runtime + shared components + landing route
├── route-<name>.[hash].wasm one per lazy route
├── app.[hash].css          scoped + atomized stylesheet
├── *.br / *.gz             precompressed siblings
├── *.map                   source maps back to .v
└── manifest.json           asset → { hash, content_type, encoding, cache, route? }
```

A vanilla request handler reads the manifest once and answers each request with
the correct `Content-Type` (notably `application/wasm`, required for
`instantiateStreaming`), `Content-Encoding` (negotiated from `Accept-Encoding`),
`Cache-Control` (immutable for hashed assets, `no-cache` for `index.html`), and
SPA fallback (serve `index.html` for unknown client routes, but still 404 for
asset-looking paths). The upstream support this needs is proposed in
[ISSUE-vanilla-static-assets.md](ISSUE-vanilla-static-assets.md).
