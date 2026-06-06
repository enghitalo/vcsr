// Phase 09 — Manifest + vanilla response building.
//
// GOAL: emit dist/manifest.json (asset → content_type, encoding, cache, route),
// and provide the pure response-building logic a vanilla `handle_request` uses.
// Following vanilla's testing style, the response logic is verified WITHOUT a
// socket — feed a raw request, assert the raw response headers/status.
//
// This phase is the contract between vcsr and vanilla; the upstream support it
// assumes is proposed in ../docs/ISSUE-vanilla-static-assets.md.
module main

import vcsr.manifest
import vcsr.serve { AssetServer }

fn server() AssetServer {
	return AssetServer.load('testdata/fixture-app/dist/manifest.json') or { panic(err) }
}

fn req(line string) []u8 {
	return (line + '\r\n\r\n').bytes()
}

// --- manifest shape ---------------------------------------------------------

fn test_manifest_maps_wasm_to_correct_mime() {
	m := manifest.load('testdata/fixture-app/dist/manifest.json')!
	e := m.entry_for('core.*.wasm')!
	assert e.content_type == 'application/wasm' // REQUIRED for instantiateStreaming
}

fn test_manifest_marks_hashed_assets_immutable() {
	m := manifest.load('testdata/fixture-app/dist/manifest.json')!
	assert m.entry_for('core.*.wasm')!.cache == 'public, max-age=31536000, immutable'
	assert m.entry_for('index.html')!.cache == 'no-cache'
}

fn test_manifest_lists_spa_fallback() {
	m := manifest.load('testdata/fixture-app/dist/manifest.json')!
	assert m.spa_fallback == 'index.html'
}

// --- response building (socket-free, vanilla style) -------------------------

fn test_serves_wasm_with_application_wasm() {
	resp := server().respond(req('GET /core.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: application/wasm')
	assert resp.contains('Cache-Control: public, max-age=31536000, immutable')
}

fn test_negotiates_brotli_when_accepted() {
	resp := server().respond(req('GET /app.abc123.js HTTP/1.1\r\nAccept-Encoding: br, gzip'))!.bytestr()
	assert resp.contains('Content-Encoding: br')
	assert resp.contains('Vary: Accept-Encoding')
}

fn test_serves_raw_when_encoding_not_accepted() {
	resp := server().respond(req('GET /app.abc123.js HTTP/1.1'))!.bytestr()
	assert !resp.contains('Content-Encoding')
}

fn test_index_html_is_no_cache() {
	resp := server().respond(req('GET / HTTP/1.1'))!.bytestr()
	assert resp.contains('Content-Type: text/html')
	assert resp.contains('Cache-Control: no-cache')
}

fn test_spa_fallback_for_client_route() {
	// a client route with no file on disk → serve index.html so refresh/deep-link work
	resp := server().respond(req('GET /users/42 HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: text/html')
}

fn test_missing_asset_looking_path_is_404_not_fallback() {
	// asset-looking 404s must NOT be masked by the SPA fallback
	resp := server().respond(req('GET /nope.9f3a1c.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404')
}

fn test_path_traversal_refused() {
	resp := server().respond(req('GET /../../etc/passwd HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 404') || resp.starts_with('HTTP/1.1 400')
}

fn test_etag_conditional_get_returns_304() {
	s := server()
	etag := s.etag_for('core.9f3a1c.wasm')!
	resp := s.respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nIf-None-Match: ' + etag))!.bytestr()
	assert resp.starts_with('HTTP/1.1 304')
}
