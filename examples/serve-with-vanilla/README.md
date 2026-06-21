# Example: serve-with-vanilla

Serve a built vcsr bundle (`dist/`) with the
[vanilla](https://github.com/enghitalo/vanilla) HTTP server.

**Runs out of the box** — with no `dist/` of its own it builds the fixture app
(from its committed `build/` wasm) and serves that:

```sh
v run examples/serve-with-vanilla/main.v        # → http://localhost:3000  (Ctrl-C to stop)
curl -s -D- -o/dev/null http://localhost:3000/core.9f3a1c.wasm   # Content-Type: application/wasm

# serve a different bundle (build it first — dist/ is generated, not committed):
vcsr build testdata/dashboard-app
VCSR_DIST=testdata/dashboard-app/dist  v run examples/serve-with-vanilla/main.v
```

It resolves the bundle in order: `$VCSR_DIST` → `./dist` → the fixture app, which
it **builds on the fly** if its (generated, un-committed) `dist/` is absent. Needs
`vanilla` on V's module path — `ln -s /path/to/vanilla ~/.vmodules/vanilla`.

> The `vcsr build` CLI is the remaining roadmap; today the bundle is produced by
> a library call — `bundle.build('testdata/fixture-app', release: true)` writes a
> `dist/` with hashed names, `.br`/`.gz` siblings, and a manifest. This is a real
> per-core epoll server; if you only want to *see* a bundle render in a browser,
> [tools/browser-smoke](../../tools/browser-smoke) does that with a lighter
> single-process server.

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
