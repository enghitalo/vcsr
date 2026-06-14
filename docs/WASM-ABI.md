# The vcsr WASM ABI — a language-neutral module contract

vcsr is two separable things:

1. a **frontend** that compiles a V component triplet (`.v`/`.html`/`.css`) to a
   WASM module, and
2. a **runtime contract + loader** — the `app.js` that instantiates modules, the
   dynamic linker that lays out core + side chunks in one shared memory, and the
   vanilla `dist/` that serves them.

Part 2 is defined entirely on the **wasm interface** — what a module
exports/imports and how DOM values cross the boundary. Nothing in it is specific
to V. So a module produced by **any** toolchain (Rust, Zig, C, AssemblyScript,
or hand-written WAT) that honors this contract loads through the same `app.js`
and is served by the same vanilla bundle. This document is that contract;
[`tests/phase_11_abi_conformance_test.v`](../tests/phase_11_abi_conformance_test.v)
checks it against non-V fixtures in
[`tests/fixtures/abi/`](../tests/fixtures/abi/).

## Two module kinds

Mirrors Emscripten `MAIN_MODULE` / `SIDE_MODULE` + `dlopen`, and the
phase-07 link plan ([`tests/phase_07_wasm_linking_test.v`](../tests/phase_07_wasm_linking_test.v)).

### MAIN module (`core.wasm`)

Owns the shared world and the runtime; carries the landing route.

| Direction | Symbol | Type | Why |
|---|---|---|---|
| **export** | `memory` | `memory` | the one linear memory shared by all chunks |
| **export** | `__indirect_function_table` | `table funcref` | the one call table; a chunk's closure lands here so core can call it |
| **export** | `__v_alloc` | `(i32) -> i32` | the single allocator; chunks import it, never redefine it |
| **export** | `__v_free` | `(i32) -> ()` | "" |
| **export** | `mount` | `(externref) -> i32` | landing route: take the host root node, return an instance id |
| **export** | `unmount` | `(i32) -> ()` | tear down an instance |
| import | host DOM ops (e.g. `env.register_template`, `env.clone_template`) | take/return `externref` | the js FFI substrate |

### SIDE module (`route-<name>.wasm`)

One per lazy route. Position-independent; imports the shared world; carries only
its own route.

| Direction | Symbol | Type | Why |
|---|---|---|---|
| **import** | `core.memory` | `memory` | use core's memory, don't define one |
| **import** | `core.__indirect_function_table` | `table funcref` | shared call table |
| **import** | `core.__memory_base` | `global i32` | relocation base for this chunk's data |
| **import** | `core.__table_base` | `global i32` | relocation base for this chunk's functions |
| **import** | `core.__v_alloc` | `(i32) -> i32` | shared allocator — **must not be redefined** |
| **export** | `mount` | `(externref) -> i32` | uniform route interface, identical to core's |
| **export** | `unmount` | `(i32) -> ()` | "" |

The loader assigns each chunk a free, **disjoint** region of the shared memory
(`__memory_base`) and table (`__table_base`) and relocates it there — so chunks
coexist in one memory without colliding.

## The DOM boundary: the one design decision that dictates language-neutrality

DOM nodes and host callbacks cross the WASM↔host boundary as **opaque handles**.
There are two ways to represent a handle, and the choice is the load-bearing one:

- **`externref` (the target ABI).** The handle is a first-class wasm reference
  value: it travels on the stack and in tables, is never serialized into linear
  memory, and is uniform across producers. This is what the table above and the
  fixtures use, and what every conforming language emits the same way.
- **Integer handle table (today's bridge for V).** The handle is an `i32` index
  into a JS-side `Map<i32, JsValue>` maintained by `app.js`. This is what you use
  when the producer can't emit `externref` yet (see the V status below). It is
  still language-neutral **only if every producer agrees on the same table
  protocol** — so if you ship the integer bridge, the protocol (allocate/lookup/
  free a handle) becomes part of *this* contract, not an implementation detail.

A conforming bundle must pick one and advertise it (`boundary_abi.dom` in the
phase-07 link plan: `.externref` or `.handle_table`). The fixtures and the
phase-07 spec target `.externref`; the integer bridge is the documented fallback.

## How V reaches this contract today (and the gap)

This matters because the contract assumes capabilities the **stock V toolchain
does not yet deliver on its own** (verified against V `130caaf`, 2026-06-13):

| Path | Compiles full V (arrays/maps/closures/stdlib)? | `externref` DOM? | MAIN/SIDE dynamic linking? |
|---|---|---|---|
| `v -b wasm` (native backend) | **No** — `gen.v` still errors `wasm backend does not support dynamic arrays`; DOM interop is `fn JS.*` passing `(ptr,len)` through linear memory, not `externref` | no (native interop is `(ptr,len)`) | no |
| `v -cc clang` → C → `clang --target=wasm32-wasip1` ([concept example](https://github.com/WebAssembly/wasi-sdk)) | **Yes** — it's V's normal C output (`-gc none` + a WASI shim in JS) | no — clang `__externref_t` exists since 2023 but [crashes at global scope (LLVM #141011, open)](https://github.com/llvm/llvm-project/issues/141011) and can't live in linear memory/structs | only by hand (`wasm-ld -shared`) |

Consequences for vcsr, today:

1. **The compile path is `v -cc clang` + wasi-sdk**, not `v -b wasm`. The native
   backend cannot compile the runtime (it needs dynamic arrays). The README
   pipeline's step 7 reflects this.
2. **`externref` for DOM is the roadmap target; the integer handle table is the
   shipping bridge.** Both are valid `boundary_abi` values precisely so vcsr can
   ship on the bridge now and migrate to `externref` when the toolchain (native
   browser backend, or clang externref maturing) catches up — without changing
   the frontend.
3. **MAIN/SIDE splitting is roadmap.** The MVP may ship a single module, or wire
   `wasm-ld -shared` manually. The phase-07 spec pins the eventual contract.

The value of writing the contract down (and testing it against non-V fixtures)
is exactly this: the frontend, the loader, and the producer language can each
move independently as long as they keep meeting at this interface.
