# wasm-reactive — Gate 1, proven: compiled-V reactivity running in wasm

A runnable proof that a vcsr-style component **can** compile to browser-ABI wasm
(Path 2: `v -cc clang` + wasi-sdk) and **run** — a reactive counter whose signal
write re-renders through an imported `(ptr,len)` host call. It also pins down the
one thing that blocks the *stock* runtime from doing this today.

This is the empirical companion to [WEB-API-SUPPORT.md](../../WEB-API-SUPPORT.md)
"Gate 1" and the corrected §2.1 of [WASM-PATHS-ANALYSIS.md](../../WASM-PATHS-ANALYSIS.md).

## The finding: V capturing closures trap on wasm

`v -cc clang` compiles the **whole** vcsr runtime to a valid wasm module — and
the WASM-PATHS matrix marks closures `✅ validate=ok`. But **validation is not
execution.** V implements capturing closures (`fn [x] () {...}`) with
runtime-generated **executable memory** (mprotect / exec pages — see
`vlib/builtin/closure/closure_nix.c.v`). wasm forbids runtime code generation, so
a captured closure that is stored and later called **traps** at the call site:

```
RuntimeError: table index is out of bounds
  at vcsr__run_tracked            ← runs effect.action, a `fn ()` closure
  at vcsr__runtime__bind_text
  at main__Counter_view
```

Isolated proof (`v -cc clang` → wasm, run in Node):

```
noncapturing() = 8              # plain fn  → a function-table index → works
capturing()    THREW: memory access out of bounds   # fn [x] → exec-thunk → traps
```

The stock vcsr runtime is built on capturing closures — `signal.v`'s effect
actions and cleanups, and **every** `runtime.bind_*` getter/handler
(`fn [mut node, get] () {...}`, `fn [mut c] () string {...}`). So the native
counter (16 green tests) compiles and validates to wasm but cannot run there.

## The fix this PoC demonstrates

Model an effect as a **top-level function + a context pointer**, never a capturing
closure. A top-level fn lowers to an ordinary function-table index (a normal
`call_indirect`), which runs on wasm. [app.v](app.v) is a complete closure-free
reactive core (`Signal`/`Effect`/`run_effect`) in exactly the shape `signal.v`
must take, plus a `Counter` whose render effect drives the host via
`env.host_set_text(ptr,len)` — the same boundary as the runtime's `set_text`.

## Run it

```sh
WASI_SDK=/opt/wasi-sdk ./build.sh      # build app.wasm (gitignored artifact; needs wasi-sdk)
node harness.mjs                       # then run the proof (Node 18+)
```

Measured (Node 26, wasi-sdk 25 / clang 19), `app.wasm` = ~82 KB:

```
boot():
   host_set_text -> "0"
inc():
   host_set_text -> "1"
inc():
   host_set_text -> "2"
inc():
   host_set_text -> "3"

✅ PASS — closure-free reactive counter compiled from V ran in wasm; a signal
   write re-ran the effect and drove the host via (ptr,len) FFI. Final DOM = "3".
```

`boot()` is mount; `inc()` is the click-handler entry point. In a browser the only
change is `env.host_set_text` doing `node.textContent = str` and `inc` wired to a
DOM event; the wasm side is identical.

## Two non-obvious build facts (both load-bearing)

- **`_vinit` must be called explicitly.** A reactor module runs C constructors via
  `_initialize`, but V registers its global init (`_vinit`) as a constructor only
  on `_WIN32`. Without an explicit `_vinit(0,0)` after `_initialize()`, V global
  state is uninitialized and the first map/string op panics `division by zero`.
  The harness calls both.
- **`C.` functions need a prototype.** V emits no C declaration for
  `fn C.host_set_text`, so [host.h](host.h) supplies one — with `import_module`/
  `import_name` attributes for a clean `(import "env" "host_set_text")` and no
  `--allow-undefined`.

## What this means for Gate 1

The toolchain spine is **ready** and the path is **proven**. Remaining work to
make the real vcsr counter run in a browser:

1. **Refactor `signal.v` closure-free** — `Effect{ action fn (voidptr), ctx
   voidptr }`; the per-signal cleanups (today `fn [mut s,e] () {...}` over a
   generic `Signal[T]`) become a typed detach via a small vtable/context, since
   generics + type-erased effect lists are the hard part.
2. **Refactor `runtime.bind_*` closure-free** — each binding becomes a top-level
   patch fn + a context struct (the component + slot index) instead of a captured
   getter/handler. Codegen (`counter.gen.v`) emits the context, not closures.
3. **A wasm DOM backend** — `runtime`'s mount/`bind_*` drive real nodes via
   imported FFI ops (`el_create`/`el_text`/`el_on`/…, the dashboard's shape)
   instead of the in-memory mock tree.
4. **Wire `v -cc clang` into `vcsr build`** — run this recipe on a component +
   the runtime and emit `core.wasm`, replacing the "prebuilt wasm required" gate
   in [cmd/vcsr/vcsr.v](../../../cmd/vcsr/vcsr.v).
