# vcsr CLI

The command-line front door to the implemented compiler. The pipeline (phases
01–11) lives in libraries; this binary wires them into the commands below.

## Build & install

`vcsr` imports `vcsr.*` and (for `serve`) `vanilla.http_server`, so both the
`vcsr` and `vanilla` modules must be on V's module path:

```sh
ln -s "$PWD" ~/.vmodules/vcsr               # import vcsr.*
ln -s /path/to/vanilla ~/.vmodules/vanilla  # for `serve` (vanilla.http_server)

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
vcsr gen    <triplet>           generate <name>.gen.v from a .v/.html/.css triplet
vcsr wasm   <src> [--out DIR]   compile a component src dir → core.wasm (v -cc clang)
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

Compiles a V component (+ the vcsr runtime) to wasm via Path 2 (`v -cc clang` +
wasi-sdk), using the runtime's host-owned-DOM backend (`-d wasm_browser`). Also
emits a default `app.js` (host loader + WASI shim) and `index.html` next to it —
unless you already ship your own (it won't clobber them).

```sh
WASI_SDK=/opt/wasi-sdk vcsr wasm examples/counter/src
# ✓ examples/counter/wasm/core.wasm (…) [+ app.js + index.html]
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
