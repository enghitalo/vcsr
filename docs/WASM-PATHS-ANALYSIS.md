# WASM-for-the-browser: the three V paths, measured

What can actually reach a browser as WebAssembly, by which route, and what each
route can and cannot do — **measured empirically**, not quoted from old blog
posts. Every ✅/❌ below is a real compile run on this machine on **2026-06-13**
(with the installed clang **19.1.5**; the decisive `externref` results in §3 were
re-verified on **2026-06-21** on the same toolchain). The reproduction commands
are in §7.

## Toolchain under test (as installed on this machine)

| Tool                              | Version                                             | Notes                                                                 |
| --------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------- |
| V                                 | `0.5.1 c0624b2`                                     | master HEAD (commit of 2026-06-20)                                    |
| clang / wasi-sdk                  | **19.1.5** (`wasi-sdk 25.0`, LLVM commit `ab4b5a2d`) | targets `wasm32`/`wasm64`. (Upstream wasi-sdk has newer LLVM 20/22 builds; the externref limit below is unchanged on those — see §3.) |
| WABT (`wat2wasm`/`wasm-validate`) | 1.0.34                                              | reference-types on by default; lags on relaxed-SIMD/memory64          |
| Binaryen (`wasm-opt`)             | 108                                                 | bundled in wasi-sdk's clang driver                                    |
| `wasm-tools`                      | 1.226.0                                            | validates all proposals; component tooling                      |
| Node                              | 26.1.0                                             | V8; tracks Chrome                                               |

**Browser baseline:** WebAssembly **3.0 was ratified by the W3C in Sept 2025**
(GC, Memory64, multi-memory, typed refs, tail calls, final exception handling,
relaxed SIMD, JS string builtins folded into core). Per-feature browser support
is in the matrix in §4; full citations in §8.

## The three paths

```
 PATH 3   .v ──────────────────────────────────▶ .wasm     v -b wasm        (native backend)
 PATH 2   .v ──▶ .c (V's cgen) ──▶ clang ───────▶ .wasm     v -cc clang + wasi-sdk
 PATH 1   .c ─────────────────────▶ clang ───────▶ .wasm     pure clang  (reachable from V via C-in-V)
```

Path 1 is "what the wasm target can do at all"; Path 2 is "what V can ship
today"; Path 3 is "what V's own backend can do without a C compiler". They form
a containment story: **Path 2 ⊇ the V language; Path 1 ⊇ the wasm proposals; and
because Path 2 goes through C, Path 1's reach is available inside Path 2 via
`C.`-interop (the C-in-V bridge, §2.4).**

---

## §1. PATH 3 — V native `-b wasm`

A pure-V wasm builder (no C compiler). Default output is **WASI**; `-os browser`
exists for DOM demos. Measured feature coverage:

| V feature                                                 | `-b wasm` | error if it fails                                                                                                                                                                                                                            |
| --------------------------------------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| int / f64 arithmetic, function export                     | ✅        | —                                                                                                                                                                                                                                            |
| `println` (→ WASI `fd_write`)                             | ✅        | —                                                                                                                                                                                                                                            |
| fixed arrays `[N]T`, `match`, `for x in a..b`, string `+` | ✅        | —                                                                                                                                                                                                                                            |
| **named structs**                                         | ✅        | (single-letter names are reserved for generics — unrelated)                                                                                                                                                                                  |
| **dynamic arrays `[]T`**                                  | ❌        | `wasm backend does not support dynamic arrays` (`gen.v:943`) / `get_wasm_type: unreachable type '[]int'`                                                                                                                                     |
| **maps**                                                  | ❌        | `get_wasm_type: unreachable type 'map[string]int'`                                                                                                                                                                                           |
| **closures**                                              | ❌        | `get_wasm_type: unreachable type 'anon_fn…'`                                                                                                                                                                                                 |
| **interfaces**                                            | ❌        | `toplevel_stmt(): unhandled node: InterfaceDecl`                                                                                                                                                                                             |
| **sum types**                                             | ❌        | `get_wasm_type: unreachable type 'main.Num' SumType`                                                                                                                                                                                         |
| **generics**                                              | ❌        | `get_wasm_type: unreachable type 'T'`                                                                                                                                                                                                        |
| `-os browser` DOM via `fn JS.*(ptr,len)`                  | ⚠️        | the model is `(ptr,len)` through linear memory, **not externref**; and the bundled official example `change_color_by_id` **crashes the compiler** on today's master: `V panic: called function eprintln does not exist` (in `v_stable_sort`) |

**Verdict.** Usable for hand-written numeric/leaf functions. It **cannot compile
a real component framework** — the vcsr runtime (signals, slot tables, router,
the `js`/`JsValue` substrate) is built from dynamic arrays, maps, closures, and
interfaces, every one of which the backend rejects. DOM crosses as `(ptr,len)`,
not `externref`. The `-os browser` path is additionally unstable (official
example crashes the compiler). **Not a candidate for vcsr today.**

---

## §2. PATH 2 — V → C → clang → `wasm32-wasip1`

V emits its normal C; `clang` (wasi-sdk) compiles it. The V step needs
`-gc none` and a few `-d` defines to drop Linux-only runtime bits
(`-d no_backtrace -d no_getpid -d no_gettid -d no_segfault_handler`); the clang
step is the reactor-model link from the [concept example](../../concept-examples).

### 2.1 The whole V language compiles — and validates

| V feature exercised                                  | result         | size (uncompressed) |
| ---------------------------------------------------- | -------------- | ------------------- |
| dynamic arrays + `.sort()` with a closure comparator | ✅ validate=ok | 72 KB               |
| maps                                                 | ✅             | 79 KB               |
| UTF-8 strings + interpolation                        | ✅             | 64 KB               |
| structs in a dynamic array                           | ✅             | 64 KB               |
| closures (capturing)                                 | ✅             | 69 KB               |
| generics                                             | ✅             | 65 KB               |
| interfaces (dynamic dispatch)                        | ✅             | 64 KB               |
| sum types + `match`                                  | ✅             | 65 KB               |

Every one passes `wasm-validate`. The floor is ~64 KB (V runtime + libc),
uncompressed — brotli cuts that sharply, and it's a one-time core cost.

### 2.2 What the browser must provide

The concept example (`print` + `sum` + `sort_array`) builds to **73,614 B** and
exports `memory`, `malloc`, `free`, and the user functions — but **imports 45
`wasi_snapshot_preview1` functions** (`fd_write`, `args_get`, `clock_time_get`,
…). Browsers have no native WASI, so a **JS WASI shim is mandatory** (exactly the
role of the example's `wasm.js`; or `@bjorn3/browser_wasi_shim` / `@wasmer/wasi`).
DOM access is JS glue reading `(ptr,len)` out of the shared linear memory.

### 2.3 The one caveat: stdlib modules with C dependencies

`import json` failed to link — V's `json` uses `cJSON.h`, a thirdparty C header
that must be compiled/linked alongside. Pure-V stdlib is fine; modules backed by
C need their C sources added to the clang step.

### 2.4 The C-in-V bridge — Path 1's reach, from V

Because Path 2 _is_ a C compile, anything C/clang can do is reachable from V via
`C.`-interop. Measured: a V program calling `C.csum` **and** a clang
`__builtin_popcount`, all riding through to wasm — **64,227 B, ✅**:

```v
#flag -I.
#include "helper.h"     // static inline int csum(int,int){...}
fn C.csum(int, int) int
@[export:'f'] pub fn f() int { return C.csum(20, 22) + ... }
```

So a capability V's frontend doesn't expose (a SIMD kernel, a hand-tuned
externref shim) can be dropped in as C and still ship through Path 2.

**Verdict.** **The only path that compiles real V today, and the production path
for vcsr.** Cost: a WASI shim + the linear-memory/handle-table DOM model (no
externref persistence — see §3).

---

## §3. PATH 1 — pure clang-19, the wasm proposal ceiling

What the _target_ can emit with LLVM 19, independent of language. This is the
upper bound Path 2 inherits through the C-in-V bridge.

| WASM proposal                                | clang-19           | how                                                                                                                                                  |
| -------------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| baseline (i32/i64/f32/f64, linear memory)    | ✅                 | default                                                                                                                                              |
| sign-extension ops                           | ✅                 | `-msign-ext`                                                                                                                                         |
| non-trapping float→int                       | ✅                 | `-mnontrapping-fptoint`                                                                                                                              |
| bulk memory                                  | ✅                 | `-mbulk-memory`                                                                                                                                      |
| multi-value returns                          | ✅                 | `-mmultivalue -Xclang -target-abi -Xclang experimental-mv`                                                                                           |
| fixed-width SIMD (v128)                      | ✅                 | `-msimd128`                                                                                                                                          |
| tail calls                                   | ✅                 | `-mtail-call` + `musttail`                                                                                                                           |
| **threads** (atomics + **shared memory**)    | ✅                 | `-matomics -mbulk-memory -pthread -Wl,--shared-memory` (browser also needs COOP/COEP)                                                                |
| extended const expressions                   | ✅                 | `-mextended-const`                                                                                                                                   |
| **exception handling** (`-fwasm-exceptions`) | ✅                 | C++ `try/catch` lowered to EH (742 B)                                                                                                                |
| Memory64 (`wasm64`)                          | ✅                 | `--target=wasm64` (WABT 1.0.34 too old to validate; `wasm-tools` OK)                                                                                 |
| reactor exec-model (`_initialize`)           | ✅                 | `-mexec-model=reactor`                                                                                                                               |
| relaxed SIMD                                 | ⚠️                 | LLVM 19 emits it, but wasi-sdk's bundled Binaryen rejects the opcodes (`invalid code after SIMD prefix: 261`); niche + Safari doesn't ship it anyway |
| **reference types / `externref`**            | ⚠️ **constrained** | see below — the decisive limit                                                                                                                       |

### externref on clang-19 — works only in transit

This is the constraint that dictates the whole DOM strategy. Measured per
scenario:

| externref usage                       | clang-19                                                                                                                                                  |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| function param / local / return value | ✅                                                                                                                                                        |
| `__builtin_wasm_ref_null_extern()`    | ✅                                                                                                                                                        |
| a global, _declared_ but unused       | ✅                                                                                                                                                        |
| a global, **stored to**               | ❌ `fatal error: error in backend: Cannot select: … store` — **LLVM [#141011](https://github.com/llvm/llvm-project/issues/141011) still live in LLVM 19** |
| a field in a struct                   | ❌ `field has sizeless type` (externref can't live in linear memory, by design)                                                                           |
| a C array / table                     | ❌ `only zero-length WebAssembly tables are currently supported`                                                                                          |

So from C/clang (and therefore from V-via-clang) you can **pass** a DOM node
across a boundary as `externref`, but you **cannot persist** it — not in a
global, a struct, or a C-managed table. A DOM framework must cache node handles,
so it needs the **integer handle table** bridge (`i32` index into a JS-side
`Map<i32, JsValue>`) regardless of `externref` existing. That is why
[WASM-ABI.md](WASM-ABI.md) makes `boundary_abi.dom` a declared choice and ships
on `.handle_table` today.

### Component Model — not a browser feature

`wasm-tools component new` on the V/WASI module fails without the WASI adapter
(`failed to encode a component from module`): components are **assembled
host-side by tooling**; **no browser runs a component natively** (confirmed in
the 2026 browser survey, §8). For the browser it's a build-time convention, not
a runtime target.

**Verdict.** clang-19 can emit essentially the entire browser-relevant proposal
set — SIMD, threads, exceptions, tail calls, multi-value, memory64, reference
types — and all of it is reachable from V through the C-in-V bridge. The lone
hard wall is **persisting `externref`**, which no toolchain gives you from C
today.

---

## §4. Master matrix: browser _need_ × path × browser support

For each capability a browser app might want: which path delivers it, and is the
browser ready (WASM 3.0 baseline; "Safari floor" is the binding constraint).

| Browser need                                         | Path 3 (V native)   | Path 2 (V→clang)            | Path 1 (pure clang)           | Browser support (verdict)                                                                     |
| ---------------------------------------------------- | ------------------- | --------------------------- | ----------------------------- | --------------------------------------------------------------------------------------------- |
| Run real app logic (arrays/maps/closures/interfaces) | ❌                  | ✅                          | n/a (lang)                    | ✅ universal                                                                                  |
| `println`/logging                                    | ✅ (WASI)           | ✅ (WASI shim)              | ✅                            | ✅ via JS shim                                                                                |
| Call DOM / JS                                        | ⚠️ `(ptr,len)` only | ✅ JS glue `(ptr,len)`      | ✅ + transient externref      | ✅ (always via JS)                                                                            |
| **Persist** DOM node handles                         | ❌                  | ✅ via **handle table**     | ❌ externref can't persist    | handle-table: ✅ everywhere; externref: ✅ Chrome96/FF79/Safari15 but **not storable from C** |
| Manual heap (malloc/free)                            | partial             | ✅                          | ✅                            | ✅                                                                                            |
| SIMD (v128)                                          | ❌                  | ✅ (C-in-V)                 | ✅ `-msimd128`                | ✅ Chrome91/FF89/**Safari16.4**                                                               |
| Threads (shared memory + atomics)                    | ❌                  | ✅ (C-in-V)                 | ✅                            | ✅ engines universal — **but needs COOP/COEP cross-origin isolation**                         |
| Exception handling                                   | ❌                  | ✅ (C++ in V)               | ✅ `-fwasm-exceptions`        | ✅ standardized exnref: Chrome137/FF131/**Safari18.4** (2025)                                 |
| Tail calls                                           | ❌                  | ✅ (C-in-V)                 | ✅ `-mtail-call`              | ✅ since Safari 18.2 (late 2024)                                                              |
| Multi-value returns                                  | ❌                  | ✅                          | ✅                            | ✅ universal                                                                                  |
| Memory64                                             | ❌                  | ✅ (`wasm64`)               | ✅                            | ⚠️ Chrome133/FF134, **not Safari** — feature-detect                                           |
| WasmGC (managed heap)                                | ❌                  | ❌ (V uses linear memory)   | ❌ (clang uses linear memory) | ✅ Chrome119/FF120/Safari18.2 — but no C/V producer                                           |
| Dynamic linking (MAIN/SIDE chunks)                   | ❌                  | ⚠️ manual `wasm-ld -shared` | ⚠️ manual                     | host-side; emulated by the JS loader                                                          |
| Component Model                                      | ❌                  | ⚠️ host-side tooling only   | ⚠️ tooling only               | ❌ no browser runs components natively                                                        |
| `instantiateStreaming`                               | ✅                  | ✅                          | ✅                            | ✅ **requires `Content-Type: application/wasm`** (vanilla `static_assets` sets it)            |

---

## §5. Browser resources / Web APIs — `fetch`, `localStorage`, and the async wrinkle

The proposal matrix (§3) is about _what wasm bytecode can express_. A real app
also needs _browser resources_: `fetch`, `localStorage`, `WebSocket`, timers,
History (for the router), `crypto`, IndexedDB. **None of these have any
wasm-level support** — exactly like the DOM, each is a JS-host capability reached
_only_ by importing a JS function and marshalling arguments/results across the
boundary. The single axis that actually differs between them is **synchronous vs
asynchronous.**

| Resource                               | Nature              | Mechanism                                                                        | Caveat                                          |
| -------------------------------------- | ------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------- |
| `localStorage` / `sessionStorage`      | **sync**, string    | import `ls_get(kptr,klen)->(vptr,vlen)` / `ls_set(…)`; strings via linear memory | none — works everywhere                         |
| `crypto.getRandomValues`               | sync                | import writes bytes into memory                                                  | already in the concept `wasm.js` (`random_get`) |
| `console`, `URL`, read `location`      | sync                | import `(ptr,len)`                                                               | none                                            |
| History `pushState` (SPA router)       | sync                | import calls `history.pushState`                                                 | none                                            |
| **`fetch`**                            | **async** (Promise) | callback or JSPI — see below                                                     | the only hard one                               |
| `WebSocket`, `EventSource`, DOM events | async/events        | callback registered in the shared table                                          | —                                               |
| `setTimeout` / `requestAnimationFrame` | async               | callback in the table                                                            | —                                               |
| IndexedDB                              | async               | callback                                                                         | —                                               |

**Sync resources are trivial** — the same `(ptr,len)` marshalling as a DOM text
write. **Async is the real design point**, because wasm has no native `await`.
Two routes:

1. **Callback model (portable).** The imported JS does the async work and, on
   resolution, **calls a wasm function back through `__indirect_function_table`**.
   This is Go's `syscall/js` model and works in every browser today. It maps
   directly onto vcsr's `boundary_abi.handle_table`: the Promise is just another
   host handle, and you wire `promise.call('then', cb)` with `cb` living in the
   shared table — the very mechanism phase 07 already requires for cross-chunk
   closures (`closures_use_shared_table`).
2. **JSPI** (suspend/resume the wasm stack to make async look sync). Per the §8
   browser survey it ships **by default only in Chrome 137**; Firefox/Safari are
   still flag/Tech-Preview — so **not portable**. Use the callback model; treat
   JSPI as an optional fast-path.

**Measured** (2026-06-13, Node 26.1.0) — a hand-written wasm module importing a
real loopback `fetch` plus `localStorage`, in
[examples/webapi-demo/](examples/webapi-demo/):

```
1) SYNC  localStorage: stored+read back 4 bytes; backing store = [['theme','dark']]
2) ASYNC fetch:        start() returned in 5.21ms; wasm result()=0  (0 ⇒ did NOT block)
                       [wasm→log] PONG-from-server-42
                       after await: callback fired=true; wasm result()=19  (expected 19)
✅ async fetch round-trip via __indirect_function_table; sync localStorage via imports
```

`start()` returns immediately with `result()=0` — proof the module doesn't block
— and the body only lands after the host writes it into linear memory and calls
the wasm callback via `table[1]`. **No JSPI involved.**

**For vcsr:** the `js` FFI substrate the [DESIGN.md](DESIGN.md) defines
(`get`/`set`/`call`/`new` over `JsValue`) already reaches _all_ of these
uniformly — `global().get('localStorage').call('getItem', …)`,
`global().call('fetch', …)`. No per-resource API is needed; what's needed is the
substrate, the integer handle table (since `externref` can't persist — §3), and
a callback dispatcher on the shared table. `fetch` is already named in
[DESIGN.md](DESIGN.md) §1 and the `examples/spa` feature list, so the callback
plumbing belongs in the runtime from the start.

## §6. What this means for vcsr

1. **Compile path = Path 2 (`v -cc clang` + wasi-sdk), not Path 3.** Confirmed by
   measurement: Path 3 can't compile the runtime; Path 2 compiles the whole
   language. Pipeline step 7 and [ARCHITECTURE.md](ARCHITECTURE.md) already
   reflect this.
2. **DOM = integer handle table now, `externref` later.** Not a preference — a
   hard toolchain limit: `externref` cannot be stored from C (LLVM #141011, §3).
   `boundary_abi.dom` stays a declared value so the frontend never changes when
   the toolchain catches up (native browser backend, or clang externref-in-memory).
3. **A WASI shim ships with the bundle.** The core imports ~45 WASI calls; budget
   a small `wasi_snapshot_preview1` shim in `app.js` (the concept `wasm.js` is the
   template).
4. **Reach for advanced proposals via C-in-V when needed.** SIMD kernels,
   threads, or a hand-written externref/handle shim can be dropped in as C and
   ride Path 2 — no V frontend change. Gate threads behind COOP/COEP.
5. **Component Model is a build convention, not a browser target** — don't design
   the loader around native component support that no browser has.
6. **Set `application/wasm`** (vanilla's `static_assets` already does) or
   `instantiateStreaming` fails.

The language-neutral contract these conclusions feed into is
[WASM-ABI.md](WASM-ABI.md); the conformance spec is
[phase 11](../tests/phase_11_abi_conformance_test.v).

---

## §7. Reproduce it

```sh
# PATH 3 — native (expect dynamic arrays/maps/closures/interfaces to fail)
printf 'fn main(){ mut a := []int{} a << 1 println(a.len.str()) }' > t.v
v -b wasm -o t.wasm t.v            # -> get_wasm_type: unreachable type '[]int'

# PATH 2 — via clang (expect full language to pass); WS = unpacked wasi-sdk 25.0
v -d no_backtrace -d no_getpid -d no_gettid -d no_segfault_handler -cc clang -gc none -o t.c t.v
"$WS/bin/clang" --sysroot="$WS/share/wasi-sysroot" --target=wasm32-wasip1 \
  -mexec-model=reactor -Wl,--no-entry -Wl,--export-all -O3 \
  -D_WASI_EMULATED_MMAN -lwasi-emulated-mman \
  -D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal -o t.wasm t.c
wasm-validate t.wasm

# PATH 1 — pure clang proposal probe (e.g. SIMD); and the externref crash
"$WS/bin/clang" --target=wasm32 -nostdlib -Wl,--no-entry -Wl,--export-all -msimd128 -O2 -o s.wasm s.c
printf 'typedef __externref_t R; R g; void set(R r){ g=r; }' > x.c
"$WS/bin/clang" --target=wasm32 -nostdlib -mreference-types -Wl,--no-entry -o x.wasm x.c  # -> backend crash (#141011)

# §5 — fetch (async) + localStorage (sync), end-to-end in Node
cd docs/examples/webapi-demo && node harness.mjs
```

---

## §8. Sources

Browser/proposal baseline (2025–2026), verified against the canonical
`features.json` behind webassembly.org and vendor release notes:

- WebAssembly feature matrix (live): https://webassembly.org/features/
- WebAssembly **3.0 ratified** (Sept 2025): https://webassembly.org/news/2025-09-17-wasm-3.0/
- States of WebAssembly (Jan 2026): https://webassembly.org/news/2026-01-21-states-of-webassembly/
- MDN `externref` (host handles, can't touch JS value directly): https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Types/externref
- MDN `instantiateStreaming` (requires `application/wasm`): https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_interface/instantiateStreaming_static
- web.dev — WasmGC + tail calls Baseline: https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline
- web.dev — cross-origin isolation (COOP/COEP for threads): https://web.dev/articles/coop-coep
- WebKit — Safari 18.4 (exnref supersedes legacy EH): https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- LLVM #141011 — `__externref_t` global-scope backend crash (open): https://github.com/llvm/llvm-project/issues/141011
- wasi-sdk: https://github.com/WebAssembly/wasi-sdk · browser WASI shim: https://github.com/bjorn3/browser_wasi_shim
- ACM Queue — "When Is WebAssembly Going to Get DOM Support?": https://queue.acm.org/detail.cfm?id=3746174
- Component Model / jco (host-side): https://component-model.bytecodealliance.org/

Path 1/2/3 results: measured on this machine, 2026-06-13, with the toolchain in
the table at the top. Commands in §7.
