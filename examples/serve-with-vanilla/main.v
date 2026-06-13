// Serve a built vcsr bundle with the vanilla HTTP server. Illustrative source:
// it depends only on `vanilla`'s http_server — vcsr's job ends at emitting the
// `dist/` directory; vanilla's `http_server.static_assets` does the serving.
// Build a bundle into ./dist first (see README).
module main

import http_server
import http_server.static_assets
import os

// Built ONCE at boot from the dist/ that `vcsr build` emitted: static_assets
// scans the bundle, precomputes a ready-to-send response for every asset and
// every precompressed sibling, and stays immutable + lock-free afterwards.
// Defaults already match vcsr's output: spa_fallback = 'index.html',
// immutable_glob = '*.[hash].*', precompressed = [.br, .gz].
const dist_dir = os.norm_path(os.join_path(os.dir(@FILE), 'dist'))

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
