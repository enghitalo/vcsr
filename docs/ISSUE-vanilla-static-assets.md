# Proposed issue for `enghitalo/vanilla`

> Copy the section below into a new issue at
> https://github.com/enghitalo/vanilla/issues — it is written as a ready-to-file
> feature request. It is the upstream support `vcsr` needs to serve a
> CSR/WASM SPA bundle correctly.

---

## Title

Serve SPA/WASM bundles: `application/wasm` MIME, precompressed-asset negotiation, immutable caching, and SPA fallback

## Summary

`vanilla` is an excellent fit for serving a static, content-hashed,
precompressed single-page-app bundle (HTML + JS + **WASM** + CSS): no per-request
rendering, just immutable bytes shipped with `sendfile`/ETag. The current
`examples/static_files` covers MIME (partial), Range, ETag, and path-traversal
safety, but four things are missing for a modern WASM SPA to work. This proposes
a small, reusable **static-asset module** (beyond the example) that handles them.

## Motivation / what breaks today

1. **`.wasm` has no MIME entry** → `mime_type()` returns
   `application/octet-stream`. Browsers then **reject**
   `WebAssembly.instantiateStreaming(fetch(...))`, which requires
   `Content-Type: application/wasm`. This is the single hard blocker for serving
   WASM at all.
2. **No precompressed-asset negotiation.** A SPA ships `app.js`, `core.wasm`,
   `app.css` plus `.br`/`.gz` siblings built ahead of time. The server should
   read `Accept-Encoding` and serve the `.br`/`.gz` file with
   `Content-Encoding` + `Vary: Accept-Encoding`, instead of recompressing per
   request (CPU) or shipping raw bytes (bandwidth).
3. **No immutable caching policy.** Content-hashed assets
   (`core.[hash].wasm`) should be `Cache-Control: public, max-age=31536000,
immutable`; `index.html` should be `no-cache` so deploys flip atomically.
   There's currently no helper to express this.
4. **No SPA fallback.** With client-side routing, a deep link or refresh on
   `/users/42` hits the server, which 404s because no such file exists. The
   server must serve `index.html` for unknown, non-asset paths so the client
   router can take over.

## Proposed API (sketch)

A `static_assets` module (works on top of the existing raw `handle_request`
contract — pure, socket-free, E2E-testable like the rest of vanilla):

```v
import http_server.static_assets

// Built once at boot from a directory (optionally a manifest the build emits).
mut assets := static_assets.new(static_assets.Config{
	root:        'dist'
	spa_fallback: 'index.html'          // serve this for unknown non-asset paths
	immutable_glob: '*.[hash].*'        // or: trust a manifest's hashed flag
	precompressed: [.br, .gz]           // prefer .br, then .gz, per Accept-Encoding
})!

fn handle_request(req []u8, fd int) ![]u8 {
	return assets.respond(req)          // raw HTTP bytes, ready for vanilla
}
```

### Minimum additions

- **MIME table** extended with at least:
  `.wasm → application/wasm`, `.mjs → text/javascript`,
  `.map → application/json`, `.webmanifest → application/manifest+json`,
  `.wasm.br`/`.js.br` resolve to the underlying type + `Content-Encoding: br`.
- **`Accept-Encoding` negotiation** selecting a precompressed sibling when
  present; always add `Vary: Accept-Encoding`.
- **`Cache-Control` policy hook**: immutable for hashed assets, `no-cache` for
  the HTML entrypoint.
- **SPA fallback**: configurable single-file fallback for unmatched routes
  (must still 404 for paths that look like assets, e.g. `*.wasm`, to avoid
  masking real 404s).

### Nice-to-have (not blocking)

- **`sendfile(2)` zero-copy** for large assets (already noted as a possible core
  improvement in `examples/static_files`).
- **`103 Early Hints` / `Link: rel=preload`** for `core.wasm` so the browser
  starts fetching the WASM while parsing `index.html`.
- **`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy:
require-corp`** as an opt-in, for apps that later use threads /
  `SharedArrayBuffer` (cross-origin isolation).

## Acceptance criteria

- `GET /core.[hash].wasm` → `200`, `Content-Type: application/wasm`,
  `Cache-Control: public, max-age=31536000, immutable`.
- `GET /app.[hash].js` with `Accept-Encoding: br` and an `app.[hash].js.br`
  present → `200`, body is the `.br` bytes, `Content-Encoding: br`,
  `Vary: Accept-Encoding`.
- `GET /users/42` (no such file) → `200` with `index.html`,
  `Cache-Control: no-cache`.
- `GET /nope.wasm` (no such file) → `404` (asset-looking paths are **not**
  SPA-fallbacked).
- `GET /../../etc/passwd` → refused (existing path-traversal protection).
- All of the above verifiable through `handle_request()` without opening a
  socket (pure response-building logic), consistent with vanilla's testing style.

## Why upstream (vs. each app reimplementing it)

Every WASM SPA served by vanilla needs exactly this, and getting the
`application/wasm` MIME, encoding negotiation, and SPA fallback subtly wrong is a
common footgun. A small shared module makes "serve a built SPA" a two-line
handler and keeps the security-critical path-traversal logic in one audited place.

I'm happy to open a PR implementing `static_assets` against the `handle_request`
contract, with the pure logic covered by tests in the existing style.
