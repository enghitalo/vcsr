// Serve a built vcsr bundle with the vanilla HTTP server. vcsr's job ends at
// emitting the `dist/` directory; vanilla's `http_server.static_assets` serves it.
//
// The `vcsr build` CLI is the remaining roadmap, so this resolves a bundle to
// serve in this order — and, since a `dist/` is generated output (not committed),
// builds the fixture app on the fly so `v run` works out of the box:
//   1. $VCSR_DIST                       (point it anywhere)
//   2. ./dist next to this file         (what `vcsr build` would emit here)
//   3. ../../testdata/fixture-app/dist  (built from its committed build/ wasm if absent)
module main

import vanilla.http_server
import vanilla.http_server.static_assets
import vcsr.bundle
import os

fn resolve_dist() string {
	here := os.dir(@FILE)
	for c in [os.getenv('VCSR_DIST'), os.join_path(here, 'dist')] {
		if c != '' && os.is_dir(c) {
			return c
		}
	}
	// Fall back to the fixture app; its dist/ is vcsr-generated and not committed,
	// so build it (from the committed build/ wasm) if it isn't there yet.
	app := os.norm_path(os.join_path(here, '..', '..', 'testdata', 'fixture-app'))
	dist := os.join_path(app, 'dist')
	if !os.is_dir(dist) {
		bundle.build(app, release: true) or { eprintln('vcsr build failed: ${err}') }
	}
	return dist
}

// Built ONCE at boot: static_assets scans the bundle, precomputes a ready-to-send
// response for every asset + precompressed sibling, and stays immutable +
// lock-free afterwards. Defaults already match vcsr's output: spa_fallback =
// 'index.html', immutable_glob = '*.[hash].*', precompressed = [.br, .gz].
const dist_dir = resolve_dist()

const assets = static_assets.new(static_assets.Config{
	root: dist_dir
}) or { panic(err) }

// vanilla hands us raw request bytes; static_assets resolves path → asset,
// negotiates Accept-Encoding, sets application/wasm + immutable Cache-Control,
// and falls back to index.html for client routes. respond_into uses zero-copy
// sendfile(2) for large bodies (and copies on TLS/non-Linux backends).
fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	assets.respond_into(req_buffer, mut out)!
}

fn main() {
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		request_handler: handle
	})!
	println('serving vcsr bundle on http://localhost:3000  (root: ${dist_dir})')
	server.run()
}
