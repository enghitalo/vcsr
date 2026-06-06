// Phase 10 — Optimization passes + end-to-end build.
//
// GOAL: the final-mile optimizations (prefetch hints, dead-route elimination,
// streaming-friendly loader) and a full end-to-end build of a fixture app whose
// output is then driven through the vanilla response builder — proving the two
// halves (vcsr emit + vanilla serve) connect.
module main

import vcsr.bundle { Bundle }
import vcsr.serve { AssetServer }

fn built() Bundle {
	return bundle.build('testdata/fixture-app', release: true) or { panic(err) }
}

fn req(line string) []u8 {
	return (line + '\r\n\r\n').bytes()
}

// --- optimization passes ----------------------------------------------------

fn test_loader_uses_streaming_instantiate() {
	js := built().text(built().find('app.*.js')!.name)!
	assert js.contains('instantiateStreaming')
}

fn test_emits_preload_for_core_wasm() {
	html := built().text('index.html')!
	// browser should start fetching the core wasm while parsing html
	assert html.contains('rel="preload"') && html.contains('.wasm')
}

fn test_generates_prefetch_hints_for_lazy_routes() {
	b := built()
	// route chunks are prefetchable on intent (hover/viewport/idle)
	assert b.meta.prefetch_routes.contains('reports')
}

fn test_dead_route_elimination() {
	// a component reachable from no route must not ship
	b := built()
	assert !b.has_symbol('UnreachableWidget')
}

fn test_no_wasi_imports_in_browser_target() {
	// browser is a first-class target; the module must not import wasi_snapshot_preview1
	b := built()
	assert !b.find('core.*.wasm')!.imports_module('wasi_snapshot_preview1')
}

// --- end-to-end: vcsr output served by vanilla ------------------------------

fn test_full_build_produces_servable_bundle() {
	b := built()
	assert b.has('index.html')
	assert b.find('app.*.js')! != none
	assert b.find('core.*.wasm')! != none
	assert b.find('app.*.css')! != none
	assert b.has('manifest.json')
}

fn test_e2e_first_load_serves_core_only() {
	// landing on '/' should reference core + landing route, not every chunk
	s := AssetServer.load('testdata/fixture-app/dist/manifest.json')!
	html := s.respond(req('GET / HTTP/1.1'))!.bytestr()
	assert html.contains('core.') && html.contains('.wasm')
	assert !html.contains('route-reports') // lazy route not on the critical path
}

fn test_e2e_wasm_is_streamable_over_vanilla() {
	s := AssetServer.load('testdata/fixture-app/dist/manifest.json')!
	resp := s.respond(req('GET /core.9f3a1c.wasm HTTP/1.1\r\nAccept-Encoding: br'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: application/wasm')
	assert resp.contains('Content-Encoding: br')
}

fn test_e2e_route_chunk_fetched_on_navigation() {
	s := AssetServer.load('testdata/fixture-app/dist/manifest.json')!
	resp := s.respond(req('GET /route-reports.abc999.wasm HTTP/1.1'))!.bytestr()
	assert resp.starts_with('HTTP/1.1 200')
	assert resp.contains('Content-Type: application/wasm')
}
