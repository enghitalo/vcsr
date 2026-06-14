# Web API demo — how WASM reaches `fetch` and `localStorage`

A runnable proof for §5 of [WASM-PATHS-ANALYSIS.md](../../WASM-PATHS-ANALYSIS.md):
every browser resource is reached the same way — an **imported JS function +
marshalling through linear memory** — and the only real distinction is
**sync vs async**.

`webapi.wat` (hand-written, language-neutral — could be V→clang output) imports a
tiny JS FFI substrate and demonstrates both:

- **`localStorage` (sync):** `ls_set`/`ls_get` imports; strings cross as `(ptr,len)`.
- **`fetch` (async, portable callback model — no JSPI):** `fetch_start` returns
  immediately; when the real fetch resolves, the host writes the body into wasm
  linear memory and calls the wasm callback back **via `__indirect_function_table`**
  (the same shared-table mechanism phase 07 specifies for cross-chunk closures).

## Run

```sh
wat2wasm webapi.wat -o webapi.wasm     # (checked in; only needed if you edit the .wat)
node harness.mjs                       # Node 18+ (global fetch); measured on Node 26.1.0
```

Measured output (2026-06-13, Node 26.1.0) — note `start()` returns with
`result()=0`, proving the module does **not** block on the fetch:

```
1) SYNC  localStorage:
     stored+read back 4 bytes; backing store = [ [ 'theme', 'dark' ] ]
2) ASYNC fetch (portable callback model):
     [host] fetch_start → http://127.0.0.1:36475/data | wasm callback = table[1] (no JSPI, pure callback)
     start() returned in 5.21ms; wasm result()=0 (0 ⇒ did NOT block)
     [wasm→log] PONG-from-server-42
     after await: callback fired=true; wasm result()=19 (expected 19)

✅ PASS — async fetch round-trip via __indirect_function_table; sync localStorage via imports
```

The harness spins a loopback HTTP server, so it is offline and deterministic. In
a browser the only change is the host functions (real `fetch`, real
`localStorage`); the wasm side is identical.
