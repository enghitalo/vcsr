// vcsr — the command-line front door to the implemented compiler.
//
// The pipeline (phases 01–11) lives in libraries; this binary wires three of
// them into commands a developer runs:
//
//   vcsr gen   <triplet>          analyze a .v/.html/.css triplet → write <name>.gen.v
//   vcsr build <app> [--release]  bundle an app dir → <app>/dist (hashing, br/gz, manifest)
//   vcsr serve <dist> [--port N]  serve a built dist/ with the vanilla HTTP server
//   vcsr version | help
//
// Browser-wasm emission is the remaining roadmap, so `build` consumes prebuilt
// browser-ABI wasm from <app>/build/ (see docs/WASM-PATHS-ANALYSIS.md). `gen`
// runs fully today.
module main

import os
import vcsr.bundle
import vcsr.component
import vanilla.http_server
import vanilla.http_server.static_assets

const version = '0.0.1'

fn main() {
	args := os.args#[1..]
	if args.len == 0 {
		usage()
		exit(1)
	}
	cmd := args[0]
	rest := args#[1..]
	match cmd {
		'gen' { do_gen(rest) or { fail(err) } }
		'build' { do_build(rest) or { fail(err) } }
		'serve' { do_serve(rest) or { fail(err) } }
		'version', '--version', '-v' { println('vcsr ${version}') }
		'help', '--help', '-h' { usage() }
		else {
			eprintln('vcsr: unknown command "${cmd}"\n')
			usage()
			exit(2)
		}
	}
}

// --- gen: triplet → name.gen.v ----------------------------------------------

fn do_gen(rest []string) ! {
	pos, _ := parse_args(rest)
	if pos.len == 0 {
		return error('gen: missing <triplet> path (e.g. examples/counter/src/counter)')
	}
	base := strip_known_ext(pos[0])
	vsrc := os.read_file('${base}.v') or { return error('gen: cannot read ${base}.v: ${err.msg()}') }
	html := os.read_file('${base}.html') or {
		return error('gen: cannot read ${base}.html: ${err.msg()}')
	}
	css := if os.exists('${base}.css') { os.read_file('${base}.css')! } else { '' }

	comp := component.analyze(v: vsrc, html: html, css: css)!
	gen := comp.codegen()!
	out := os.join_path(os.dir(base), gen.filename)
	os.write_file(out, gen.source)!
	println('✓ generated ${out}  (compiles_with_stock_v=${gen.compiles_with_stock_v})')
}

// --- build: app dir → app/dist ----------------------------------------------

fn do_build(rest []string) ! {
	pos, flags := parse_args(rest)
	if pos.len == 0 {
		return error('build: missing <app> directory (e.g. testdata/dashboard-app)')
	}
	app := pos[0]
	// A bundle-ready app ships an app.json + prebuilt browser-ABI wasm in build/.
	// The examples/ apps are vcsr-dialect authoring source (no app.json, no
	// prebuilt wasm — V can't emit browser wasm yet), so point the user at `gen`.
	if !os.exists(os.join_path(app, 'app.json')) {
		return error('build: "${app}" is not a bundle-ready app — no app.json.
  `build` bundles an app dir with app.json + prebuilt build/*.wasm (e.g. testdata/dashboard-app).
  The examples/ apps are vcsr-dialect source; generate a component instead:  vcsr gen <triplet>')
	}
	if !os.exists(os.join_path(app, 'build', 'core.wasm')) {
		return error('build: "${app}/build/core.wasm" not found — no prebuilt browser-ABI wasm to bundle.
  V cannot emit browser wasm yet, so an app must ship its compiled core.wasm in build/ (see docs/WASM-PATHS-ANALYSIS.md).')
	}
	b := bundle.build(app, release: 'release' in flags)!
	dist := os.join_path(app, 'dist')
	println('✓ built ${app} → ${dist}/')
	println('  wasm_opt=${b.meta.wasm_opt_level}  stripped=${b.meta.names_stripped}  prefetch=${b.meta.prefetch_routes}')
	mut files := os.ls(dist) or { []string{} }
	files.sort()
	mut total := i64(0)
	mut n := 0
	for f in files {
		p := os.join_path(dist, f)
		if !os.is_file(p) {
			continue // skip any nested dirs — only count emitted assets
		}
		sz := os.file_size(p)
		total += i64(sz)
		n++
		println('  ${f:-34} ${sz:9} B')
	}
	println('  ${n} files, ${total} B total')
}

// --- serve: dist/ via vanilla -----------------------------------------------

fn do_serve(rest []string) ! {
	pos, flags := parse_args(rest)
	if pos.len == 0 {
		return error('serve: missing <dist> directory (e.g. testdata/dashboard-app/dist)')
	}
	dist := pos[0]
	port := parse_port(flags['port'] or { '3000' })!
	assets := static_assets.new(static_assets.Config{ root: dist })!
	mut backend := http_server.IOBackend.epoll
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	// `assets` is built once and is read-only thereafter (static_assets.AssetServer
	// only reads its maps in respond_into), so capturing it in the handler and
	// sharing it across the server's workers needs no lock — same as the const+
	// top-level-fn form in examples/serve-with-vanilla.
	mut server := http_server.new_server(
		port:            port
		io_multiplexing: backend
		request_handler: fn [assets] (req []u8, _ int, mut out []u8) ! {
			assets.respond_into(req, mut out)!
		}
	)!
	println('vcsr: serving ${dist} on http://localhost:${port}  (Ctrl-C to stop)')
	server.run()
}

// --- helpers ----------------------------------------------------------------

// parse_args splits positionals from flags. `--out X`/`--port N` take a value;
// every other `--flag` is a boolean ('true').
fn parse_args(a []string) ([]string, map[string]string) {
	mut pos := []string{}
	mut flags := map[string]string{}
	mut i := 0
	for i < a.len {
		x := a[i]
		if x.starts_with('--') {
			key := x[2..]
			if key in ['out', 'port'] && i + 1 < a.len && !a[i + 1].starts_with('--') {
				flags[key] = a[i + 1]
				i += 2
				continue
			}
			flags[key] = 'true'
		} else {
			pos << x
		}
		i++
	}
	return pos, flags
}

// parse_port validates a port is 1..65535. V's string.int() silently yields 0
// on a non-numeric value (which would bind an ephemeral port), so guard it.
fn parse_port(s string) !int {
	if s == '' || !s.bytes().all(it >= `0` && it <= `9`) {
		return error('serve: invalid --port "${s}" (expected 1..65535)')
	}
	p := s.int()
	if p < 1 || p > 65535 {
		return error('serve: --port ${p} out of range (1..65535)')
	}
	return p
}

fn strip_known_ext(p string) string {
	for ext in ['.v', '.html', '.css'] {
		if p.ends_with(ext) {
			return p#[..-ext.len]
		}
	}
	return p
}

fn fail(err IError) {
	eprintln('vcsr: ${err.msg()}')
	exit(1)
}

fn usage() {
	println('vcsr ${version} — CSR→WASM compiler for V (phases 01–11 implemented)

USAGE:
  vcsr gen   <triplet>            generate <name>.gen.v from a .v/.html/.css triplet
  vcsr build <app> [--release]    bundle an app dir → <app>/dist (hashing, br/gz, manifest)
  vcsr serve <dist> [--port N]    serve a built dist/ with the vanilla HTTP server
  vcsr version | help

EXAMPLES:
  vcsr gen   examples/counter/src/counter
  vcsr build testdata/dashboard-app --release
  vcsr serve testdata/dashboard-app/dist --port 3000

NOTE: browser-wasm emission is roadmap; `build` consumes prebuilt browser-ABI
wasm from <app>/build/ (see docs/WASM-PATHS-ANALYSIS.md). `gen` runs fully today.')
}
