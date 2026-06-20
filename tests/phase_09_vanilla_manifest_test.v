// Phase 09 — Manifest + a `static_assets`-consumable `dist/`.
//
// GOAL: emit dist/manifest.json — vcsr's own BUILD RECORD (per-asset hash,
// route→chunk map, preload hints, the SPA-fallback entrypoint) — and a dist/
// LAYOUT that vanilla's http_server.static_assets serves as-is.
//
// vcsr builds no HTTP responses of its own. That logic now lives upstream:
// vanilla issue #19 shipped the http_server.static_assets module, which derives
// Content-Type / Cache-Control / Content-Encoding from the FILENAMES plus its
// `*.[hash].*` immutable glob — it does NOT read manifest.json. So vcsr's side of
// the contract is about emitting the right filenames, siblings, and entrypoint.
//
// This phase pins down that emit contract (pure vcsr, socket-free). The wire-level
// proof — driving this dist/ through static_assets — is phase 10. See
// ../docs/VANILLA-STATIC-ASSETS.md.
module main

import vcsr.manifest
import os

const dist = 'testdata/fixture-app/dist'

// --- manifest: vcsr's build record ------------------------------------------

fn test_manifest_records_asset_content_hashes() {
	m := manifest.load('${dist}/manifest.json')!
	// each asset carries the content hash baked into its filename — the loader and
	// integrity checks read this; the hash is what makes static_assets' immutable
	// glob match and lets deploys swap index.html atomically.
	e := m.entry_for('core.*.wasm')!
	assert e.content_type == 'application/wasm' // recorded for tooling (not the server)
	assert e.cache == 'public, max-age=31536000, immutable'
}

fn test_manifest_marks_index_html_no_cache() {
	m := manifest.load('${dist}/manifest.json')!
	assert m.entry_for('index.html')!.cache == 'no-cache'
}

fn test_manifest_names_spa_fallback_entrypoint() {
	m := manifest.load('${dist}/manifest.json')!
	assert m.spa_fallback == 'index.html'
}

// --- dist/ layout: what makes it static_assets-consumable -------------------
// static_assets derives MIME/cache/encoding from the FILES + the `*.[hash].*`
// glob, so the emit contract is about filenames and siblings, not headers.

fn test_assets_are_content_hashed() {
	// hashed names so static_assets' immutable glob (`*.[hash].*`) matches them
	assert glob_one('${dist}/core.*.wasm') != ''
	assert glob_one('${dist}/app.*.js') != ''
	assert glob_one('${dist}/app.*.css') != ''
}

fn test_index_html_is_unhashed_entrypoint() {
	// the SPA fallback target stays unhashed so a deploy flips by swapping it
	assert os.exists('${dist}/index.html')
	// no hashed `index.<hash>.html` variant: the only index*.html is the
	// unhashed entrypoint. (Checked as a set because V's os.glob treats `*` as
	// matching empty, so `index.*.html` also matches plain `index.html`.)
	idx := os.glob('${dist}/index*.html') or { [] }
	assert idx.len == 1 && idx[0].ends_with('/index.html')
}

fn test_precompressed_siblings_present() {
	// prebuilt .br/.gz siblings let static_assets negotiate Accept-Encoding
	// without recompressing per request
	js := glob_one('${dist}/app.*.js')
	assert js != ''
	assert os.exists('${js}.br') || os.exists('${js}.gz')
}

fn test_wasm_has_precompressed_sibling() {
	wasm := glob_one('${dist}/core.*.wasm')
	assert wasm != ''
	assert os.exists('${wasm}.br') || os.exists('${wasm}.gz')
}

// helper: first filesystem path matching a glob, or '' -----------------------
fn glob_one(pattern string) string {
	matches := os.glob(pattern) or { return '' }
	return if matches.len > 0 { matches[0] } else { '' }
}
