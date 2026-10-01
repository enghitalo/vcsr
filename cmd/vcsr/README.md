# vcsr CLI

The command-line front door to the implemented compiler. The pipeline (phases
01–11) lives in libraries; this binary wires them into the commands below.

## Build & install

`vcsr` imports `vcsr.*` and (for `serve`) `enghitalo.vanilla.server`/`.static_assets`,
so both the `vcsr` and `vanilla` modules must be on V's module path:

```sh
ln -s "$PWD" ~/.vmodules/vcsr               # import vcsr.*
v install enghitalo.vanilla                 # for `serve` (vanilla.server)

make install        # build + install to ~/.local/bin/vcsr (override PREFIX=)
make build          # just build in place → cmd/vcsr/vcsr
```

Once installed, keep it current straight from the CLI:

```sh
vcsr update         # git pull --ff-only origin, then rebuild + reinstall this binary
vcsr update --rebuild   # skip git; just rebuild + reinstall the current source
```

(`make update` does the same as `vcsr update`.) `vcsr update` replaces the running
binary atomically (build to a temp, then rename), so it's safe to run in place.

## Commands

```
vcsr gen    <triplet|dir>       generate <name>.gen.v for a triplet (or each in a dir)
vcsr wasm   <src> [--out DIR]   gen + compile a component src dir → core.wasm + vcsr_host.js
vcsr build  <app> [--release]   bundle an app dir → <app>/dist (hashing, br/gz, manifest)
vcsr serve  <dist> [--port N]   serve a dir over HTTP (sets Content-Type: application/wasm)
vcsr update [--rebuild]         git pull + rebuild + reinstall this binary
vcsr version | help
```

### `gen` — triplet → plain-V `view()`/`style()`

```sh
vcsr gen examples/counter/src/counter
# ✓ generated examples/counter/src/counter.gen.v  (compiles_with_stock_v=true)
```

### `wasm` — component → browser-ABI `core.wasm` + a runnable bundle

Regenerates every triplet's `*.gen.v` in `<src>`, then compiles the components
(+ the vcsr runtime) to wasm via Path 2 (`v -cc clang` + wasi-sdk), using the
runtime's host-owned-DOM backend (`-d wasm_browser`). Next to `core.wasm` it
writes:

- `vcsr_host.js` — the browser side of the DOM ABI + a WASI shim. **Owned by
  vcsr**: rewritten on every build so it always matches the module's imports.
- `app.js` + `index.html` — defaults, written only if absent (yours are never
  clobbered). `app.js` just imports `boot()` from `./vcsr_host.js`; vcsr warns
  if an existing `app.js` doesn't.

```sh
WASI_SDK=/opt/wasi-sdk vcsr wasm examples/counter/src
# ✓ examples/counter/wasm/core.wasm (…)
vcsr serve examples/counter/wasm           # then open the printed URL
```

See [examples/counter/wasm](../../examples/counter/wasm) and
[docs/WASM-PATHS-ANALYSIS.md](../../docs/WASM-PATHS-ANALYSIS.md) §2.1 (why the
backend is map-free + closure-free).

### `build` — bundle a prebuilt app

```sh
vcsr build testdata/dashboard-app --release
# ✓ built testdata/dashboard-app → testdata/dashboard-app/dist/
```

`build` bundles an app that ships a prebuilt `build/*.wasm` + `app.json` (the
`testdata/*` apps). To compile wasm from a V component instead, use `wasm`.

### `serve` — serve a bundle (or a `wasm` output dir)

```sh
vcsr serve testdata/dashboard-app/dist --port 3000     # Ctrl-C to stop
```

A real per-core epoll server (vanilla) that sets `application/wasm`. To just *see*
a bundle render in a browser, [tools/browser-smoke](../../tools/browser-smoke)
uses a lighter single-process server.

## End-to-end

```sh
vcsr wasm  examples/counter/src && vcsr serve examples/counter/wasm   # compiled-V counter in the browser
vcsr build testdata/dashboard-app && vcsr serve testdata/dashboard-app/dist
```
