# vcsr CLI

The command-line front door to the implemented compiler. The pipeline (phases
01–11) lives in libraries; this binary wires three of them into commands.

## Build & install

`vcsr` imports `vcsr.*` and (for `serve`) vanilla's `http_server`, so both must
be on V's module path:

```sh
ln -s "$PWD" ~/.vmodules/vcsr                                   # import vcsr.*
ln -s ~/.vmodules/vanilla/http_server ~/.vmodules/http_server  # for `serve`

v -prod -o ~/.local/bin/vcsr cmd/vcsr/      # install on PATH
# or just build it in place:  v -o cmd/vcsr/vcsr cmd/vcsr/
```

## Commands

```
vcsr gen   <triplet>            generate <name>.gen.v from a .v/.html/.css triplet
vcsr build <app> [--release]    bundle an app dir → <app>/dist (hashing, br/gz, manifest)
vcsr serve <dist> [--port N]    serve a built dist/ with the vanilla HTTP server
vcsr version | help
```

### `gen` — runs fully today

Analyzes a component triplet and writes the plain-V `view()`/`style()`:

```sh
vcsr gen examples/counter/src/counter
# ✓ generated examples/counter/src/counter.gen.v  (compiles_with_stock_v=true)
```

### `build` — bundle an app

```sh
vcsr build testdata/dashboard-app --release
# ✓ built testdata/dashboard-app → testdata/dashboard-app/dist/
#   wasm_opt=Oz  stripped=true  prefetch=[]
#   core.b96afd.wasm  …  app.<hash>.js/.css (+ .br/.gz), index.html, manifest.json
```

Browser-wasm *emission* is the remaining roadmap, so `build` consumes prebuilt
browser-ABI wasm from `<app>/build/` (see
[docs/WASM-PATHS-ANALYSIS.md](../../docs/WASM-PATHS-ANALYSIS.md)). It works on the
`testdata/*` apps that ship a `build/`; the `examples/*` apps are
authoring-experience source without prebuilt wasm.

### `serve` — serve a bundle

```sh
vcsr serve testdata/dashboard-app/dist --port 3000     # Ctrl-C to stop
```

A real per-core epoll server (vanilla). To just *see* a bundle render in a
browser, [tools/browser-smoke](../../tools/browser-smoke) uses a lighter
single-process server.

## End-to-end

```sh
vcsr build testdata/dashboard-app && vcsr serve testdata/dashboard-app/dist
```
