// Serve a built vcsr bundle with the vanilla HTTP server. Illustrative source:
// it depends on `vcsr.serve` (the bundle's manifest-driven asset server) and on
// `vanilla`'s http_server. Build a bundle into ./dist first (see README).
module main

import http_server
import vcsr.serve { AssetServer }

// Loaded once at boot from the manifest `vcsr build` emitted next to dist/.
__global g_assets = AssetServer.load('dist/manifest.json') or { panic(err) }

// vanilla hands us raw request bytes; AssetServer returns raw HTTP response
// bytes — correct Content-Type/Encoding/Cache-Control + SPA fallback included.
fn handle_request(req_buffer []u8, client_conn_fd int) ![]u8 {
	return g_assets.respond(req_buffer)
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		request_handler: handle_request
		io_multiplexing: $if linux {
			.epoll
		} $else $if darwin {
			.kqueue
		} $else {
			.iocp
		}
	})
	println('serving vcsr bundle on http://localhost:3000')
	server.run()
}
