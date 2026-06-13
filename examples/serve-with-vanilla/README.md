# Example: serve-with-vanilla

Serve a built vcsr bundle (`dist/`) with the
[vanilla](https://github.com/enghitalo/vanilla) HTTP server.

```sh
# 1) build an app (e.g. the spa example) into ./dist
vcsr build ../spa/src --out dist --release

# 2) run this server over the bundle
v -prod run .
```

[main.v](main.v) is the whole integration: point `static_assets.new` at the
`dist/` that `vcsr build` wrote, then call `assets.respond_into(req, mut out)`
from vanilla's request handler. `http_server.static_assets` handles the parts
that are easy to get subtly wrong:

- `*.wasm` → `Content-Type: application/wasm` (required for
  `WebAssembly.instantiateStreaming`)
- `Accept-Encoding: br`/`gzip` → serve the precompressed sibling +
  `Content-Encoding` + `Vary: Accept-Encoding`
- hashed assets → `Cache-Control: public, max-age=31536000, immutable`;
  `index.html` → `no-cache`
- unknown client route (e.g. `/reports/42`) → serve `index.html` (SPA fallback),
  but asset-looking 404s stay 404
- ETag/304, Range/206, HEAD, and `../` path-traversal refusal are built in
- large bodies stream with zero-copy `sendfile(2)` via `respond_into`

> This module landed in vanilla as
> [issue #19](https://github.com/enghitalo/vanilla/issues/19) (commit
> [50df944](https://github.com/enghitalo/vanilla/commit/50df94495be7bad95dc5cbc6e6be7fe53dd7fcb7));
> the integration is documented in
> [docs/VANILLA-STATIC-ASSETS.md](../../docs/VANILLA-STATIC-ASSETS.md). vcsr's job
> ends at emitting a `dist/` whose filenames and `.br`/`.gz` siblings match what
> the module expects — it ships no server of its own.

The response logic is pure (request bytes → response bytes) and lives in vanilla,
which tests it without a socket. vcsr's side — that the emitted `dist/` is
servable — is pinned by the phase-09 spec in
[../../tests/phase_09_vanilla_manifest_test.v](../../tests/phase_09_vanilla_manifest_test.v).
