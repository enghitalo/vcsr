// Phase 08 — Bundle emission: dist/ + hashing + brotli + source maps.
//
// GOAL: write the servable bundle. Empty-body index.html that loads the hashed
// loader; content-hashed filenames for every cacheable asset; precompressed
// (.br/.gz) siblings for text/wasm; source maps; and the single app.css. This
// is what vanilla will serve.
module main

import vcsr.bundle { Bundle }

fn built() Bundle {
	return bundle.build('testdata/fixture-app', release: true) or { panic(err) }
}

fn test_emits_entry_html_with_empty_body() {
	b := built()
	html := b.text('index.html')!
	assert html.contains('<body></body>') || html.contains('<body><!--')
	assert html.contains('app.') && html.contains('.js')
}

fn test_assets_are_content_hashed() {
	b := built()
	// e.g. core.9f3a1c.wasm — the hash is part of the name
	assert b.find('core.*.wasm')!.name.split('.').len == 3
	assert b.find('app.*.css')!.name != ''
	assert b.find('app.*.js')!.name != ''
}

fn test_index_html_is_not_hashed() {
	b := built()
	// the entrypoint keeps a stable name so deploys flip atomically
	assert b.has('index.html')
}

fn test_precompressed_siblings_exist() {
	b := built()
	js := b.find('app.*.js')!
	assert b.has(js.name + '.br')
	assert b.has(js.name + '.gz')
	wasm := b.find('core.*.wasm')!
	assert b.has(wasm.name + '.br') // wasm compresses very well
}

fn test_source_maps_emitted() {
	b := built()
	js := b.find('app.*.js')!
	assert b.has(js.name + '.map')
}

fn test_lazy_routes_become_separate_wasm_files() {
	b := built()
	// fixture has a lazy /reports route
	assert b.find('route-reports.*.wasm')!.name != ''
}

fn test_brotli_is_smaller_than_raw() {
	b := built()
	wasm := b.find('core.*.wasm')!
	raw := b.bytes(wasm.name)!.len
	br := b.bytes(wasm.name + '.br')!.len
	assert br < raw
}

fn test_release_runs_size_optimizer() {
	b := built()
	assert b.meta.wasm_opt_level == 'Oz' // size-optimized in release
	assert b.meta.names_stripped
}

fn test_default_loader_wires_sync_web_apis() {
	// the generated loader (no custom src/loader.js in the fixture) must expose the
	// synchronous Web-API host imports from docs/WEB-API-SUPPORT.md, not just the
	// DOM template ops. Async resources (fetch/timers/sockets/IDB) stay out.
	b := built()
	js := b.text(b.find('app.*.js')!.name)!
	assert js.contains('ls_get(') && js.contains('ls_set(') // localStorage
	assert js.contains('ss_get(') && js.contains('ss_set(') // sessionStorage
	assert js.contains('host_log(') // console
	assert js.contains('random_get(') // crypto.getRandomValues
	assert js.contains('loc_read(') // read location
	assert js.contains('history_push(') // history.pushState
	assert !js.contains('fetch_start') && !js.contains('ws_open') // async: deliberately absent
}
