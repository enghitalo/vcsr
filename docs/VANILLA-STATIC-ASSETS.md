# Serving vcsr bundles: vanilla's `http_server.static_assets`

> **Status: IMPLEMENTED upstream.** This began as a vcsr feature request and is
> now shipped in vanilla — [issue #19][issue] was closed by [commit 50df944][commit]
> as the `http_server.static_assets` module (plus zero-copy `sendfile(2)`). vcsr
> **targets** this module: `vcsr build` emits a `dist/` bundle that
> `static_assets` serves directly — vcsr ships no server of its own. The original
> upstream proposal is preserved at the bottom for provenance.

[issue]: https://github.com/enghitalo/vanilla/issues/19
[commit]: https://github.com/enghitalo/vanilla/commit/50df94495be7bad95dc5cbc6e6be7fe53dd7fcb7

## What vanilla now provides

`http_server.static_assets` turns a built SPA bundle directory into a lock-free
asset server with an allocation-free hot path. Built once at boot from
`root: 'dist'`, it precomputes a ready-to-send HTTP response for every asset and
every precompressed representation, then shares them immutably across all worker
threads:

- **`application/wasm` MIME** — required for `WebAssembly.instantiateStreaming`.
- **Precompressed negotiation** — serves the prebuilt `.br`/`.gz` sibling per
  `Accept-Encoding`, with `Content-Encoding` + `Vary: Accept-Encoding`.
- **Caching policy** — content-hashed assets (matching `immutable_glob`, default
  `*.[hash].*`) get `Cache-Control: public, max-age=31536000, immutable`; the
  unhashed `index.html` gets `no-cache` so deploys flip atomically by swapping it.
- **SPA fallback** — unknown, non-asset paths serve `index.html`; asset-looking
  404s (`/nope.[hash].wasm`) stay 404; `../` traversal is refused.
- **ETag/304, Range/206, HEAD** — conditional and partial GETs.
- **Zero-copy `sendfile(2)`** for bodies ≥ `sendfile_min_bytes` (default 256 KiB),
  used via `respond_into`, with a buffered fallback on TLS / non-Linux backends.

The whole request handler is two lines:

```v
import vanilla.http_server
import vanilla.http_server.static_assets

// Built ONCE at boot from the dist/ directory; immutable and lock-free after.
const assets = static_assets.new(static_assets.Config{
	root: 'dist'
	// defaults: spa_fallback = 'index.html', immutable_glob = '*.[hash].*',
	//           precompressed = [.br, .gz], sendfile_min_bytes = 256 KiB
}) or { panic(err) }

fn handle(req []u8, _ int, mut out []u8) ! {
	assets.respond_into(req, mut out)! // sendfile fast path; respond() is the pure-bytes API
}
```

See vanilla's `examples/static_assets` and
`http_server/static_assets/static_assets_test.v` for the full surface.

## vcsr's side of the contract

Because the security-critical, easy-to-get-wrong response logic now lives in
vanilla, vcsr's job is purely to **emit a `dist/` that `static_assets` can
consume**:

- content-hashed asset names (`core.[hash].wasm`, `app.[hash].js`,
  `app.[hash].css`, `route-<name>.[hash].wasm`) that match the `*.[hash].*`
  immutable glob;
- an **unhashed `index.html`** entrypoint — the SPA fallback target, served
  `no-cache`;
- precompressed `.br`/`.gz` siblings for the text/wasm assets;
- a `manifest.json` that is vcsr's **own build record** (per-asset hash,
  route→chunk map, preload hints) consumed by the JS loader and tooling.

> `static_assets` derives MIME, encoding, and cache policy from the files on disk
> plus the glob — it does **not** read `manifest.json`. The manifest is vcsr's
> internal record (and drives the loader/preload hints), not the server's header
> source. Getting the *filenames and siblings* right is what makes vanilla serve
> the bundle correctly.

The phase-09 spec pins down this emit contract; phase-10 drives a built bundle
through `static_assets` end-to-end to prove the two halves connect.

## Acceptance criteria (now satisfied upstream)

- [x] `GET /core.[hash].wasm` → `200`, `Content-Type: application/wasm`,
  `Cache-Control: public, max-age=31536000, immutable`.
- [x] `GET /app.[hash].js` with `Accept-Encoding: br` and an `app.[hash].js.br`
  present → `200`, `.br` bytes, `Content-Encoding: br`, `Vary: Accept-Encoding`.
- [x] `GET /users/42` (no such file) → `200` with `index.html`, `no-cache`.
- [x] `GET /nope.[hash].wasm` (no such file) → `404` (asset-looking paths are
  **not** SPA-fallbacked).
- [x] `GET /../../etc/passwd` → refused.
- [x] All verifiable through the handler without opening a socket (pure
  response-building logic), consistent with vanilla's testing style.

---

<details>
<summary>Original upstream proposal (historical — filed as issue #19)</summary>

> The text below is the feature request vcsr filed at
> https://github.com/enghitalo/vanilla/issues/19. It is kept for provenance; the
> module it proposes now exists (see above).

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
import vanilla.http_server.static_assets

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

</details>
