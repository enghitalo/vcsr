# Example: serve-with-vanilla

Serve a built vcsr bundle (`dist/`) with the
[vanilla](https://github.com/enghitalo/vanilla) HTTP server.

```sh
# 1) build an app (e.g. the spa example) into ./dist
vcsr build ../spa/src --out dist --release

# 2) run this server over the bundle
v -prod run .
```

[main.v](main.v) is the whole integration: load the manifest `vcsr build` wrote,
then return `assets.respond(req)` from vanilla's `handle_request`. The
`AssetServer` handles the parts that are easy to get subtly wrong:

- `*.wasm` → `Content-Type: application/wasm` (required for
  `WebAssembly.instantiateStreaming`)
- `Accept-Encoding: br`/`gzip` → serve the precompressed sibling +
  `Content-Encoding` + `Vary: Accept-Encoding`
- hashed assets → `Cache-Control: public, max-age=31536000, immutable`;
  `index.html` → `no-cache`
- unknown client route (e.g. `/reports/42`) → serve `index.html` (SPA fallback),
  but asset-looking 404s stay 404
- ETag / `If-None-Match` and `Range` reuse vanilla's existing support

> These capabilities are proposed upstream in
> [docs/ISSUE-vanilla-static-assets.md](../../docs/ISSUE-vanilla-static-assets.md).
> Until they land in vanilla, `vcsr.serve.AssetServer` provides them on top of
> vanilla's raw `handle_request` contract.

Because response building is pure (request bytes → response bytes), it is
testable without opening a socket — see the phase-09 spec in
[../../tests/phase_09_vanilla_manifest_test.v](../../tests/phase_09_vanilla_manifest_test.v).
