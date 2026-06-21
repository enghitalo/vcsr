// vcsr — the command-line front door to the implemented compiler.
//
// The pipeline (phases 01–11) lives in libraries; this binary wires them into
// commands a developer runs:
//
//   vcsr gen   <triplet>          analyze a .v/.html/.css triplet → write <name>.gen.v
//   vcsr wasm  <src> [--out DIR]  compile a component src dir → core.wasm (v -cc clang)
//   vcsr build <app> [--release]  bundle an app dir → <app>/dist (hashing, br/gz, manifest)
//   vcsr serve <dist> [--port N]  serve a built dist/ with the vanilla HTTP server
//   vcsr version | help
//
// `wasm` emits a browser-ABI core.wasm from a V component via Path 2 (v -cc clang
// + wasi-sdk), using the runtime's host-owned-DOM backend (the native mock tree's
// string-keyed maps + closures don't run on wasm — see docs/WASM-PATHS-ANALYSIS.md
// §2.1, examples/counter/wasm). `build` still consumes prebuilt wasm from
// <app>/build/.
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
		'gen' {
			do_gen(rest) or { fail(err) }
		}
		'wasm' {
			do_wasm(rest) or { fail(err) }
		}
		'build' {
			do_build(rest) or { fail(err) }
		}
		'serve' {
			do_serve(rest) or { fail(err) }
		}
		'version', '--version', '-v' {
			println('vcsr ${version}')
		}
		'help', '--help', '-h' {
			usage()
		}
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
	vsrc := os.read_file('${base}.v') or {
		return error('gen: cannot read ${base}.v: ${err.msg()}')
	}
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

// --- wasm: component src dir → core.wasm (Path 2; host-owned-DOM backend) ----
//
// Runs the V→C→clang recipe with -d wasm_browser so the runtime compiles its
// map-free, closure-free wasm backend (the native mock tree uses string-keyed
// maps + closures, neither of which run on wasm — see docs/WASM-PATHS-ANALYSIS.md
// §2.1). Needs an unpacked wasi-sdk (set WASI_SDK, default /opt/wasi-sdk).
fn do_wasm(rest []string) ! {
	pos, flags := parse_args(rest)
	if pos.len == 0 {
		return error('wasm: missing <component src> dir (e.g. examples/counter/src)')
	}
	src := pos[0]
	if !os.is_dir(src) {
		return error('wasm: "${src}" is not a directory')
	}
	out := flags['out'] or { os.join_path(os.dir(src.trim_right('/')), 'wasm') }
	os.mkdir_all(out)!

	wasi_sdk := if w := os.getenv_opt('WASI_SDK') { w } else { '/opt/wasi-sdk' }
	clang := os.join_path(wasi_sdk, 'bin', 'clang')
	sysroot := os.join_path(wasi_sdk, 'share', 'wasi-sysroot')
	if !os.exists(clang) || !os.is_dir(sysroot) {
		return error('wasm: wasi-sdk not found at ${wasi_sdk} — set WASI_SDK to an unpacked wasi-sdk')
	}
	// repo root holds runtime/vcsr_host.h (the DOM-ABI prototypes the C needs).
	runtime_inc := os.join_path(os.dir(os.dir(os.dir(@FILE))), 'runtime')
	cfile := os.join_path(out, 'core.c')
	wasmfile := os.join_path(out, 'core.wasm')

	// 1) V → C, host-owned-DOM backend (-d wasm_browser); strip Linux-only bits.
	run_step('V→C',
		'${os.quoted_path(@VEXE)} -d wasm_browser -d no_backtrace -d no_getpid -d no_gettid -d no_segfault_handler -enable-globals -cc clang -gc none -o ${os.quoted_path(cfile)} ${os.quoted_path(src)}')!

	// 2) C → wasm, reactor model; -I runtime for vcsr_host.h.
	run_step('C→wasm',
		'${os.quoted_path(clang)} --sysroot=${os.quoted_path(sysroot)} --target=wasm32-wasip1 -mexec-model=reactor -Wl,--no-entry -Wl,--export-all -Wl,--strip-all -I ${os.quoted_path(runtime_inc)} -D_WASI_EMULATED_MMAN -lwasi-emulated-mman -D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal -O3 -o ${os.quoted_path(wasmfile)} ${os.quoted_path(cfile)}')!

	os.rm(cfile) or {}
	println('✓ ${wasmfile}  (${os.file_size(wasmfile)} B)')

	// emit a runnable default loader + page, but never clobber a customized one
	// (same "default unless the app ships its own" rule as bundle's loader_js).
	app_js := os.join_path(out, 'app.js')
	if !os.exists(app_js) {
		os.write_file(app_js, $embed_file('templates/wasm_loader.js').to_string())!
		println('+ ${app_js}  (default host loader — edit freely; re-runs keep it)')
	}
	index_html := os.join_path(out, 'index.html')
	if !os.exists(index_html) {
		os.write_file(index_html, $embed_file('templates/wasm_index.html').to_string())!
		println('+ ${index_html}')
	}
	println('  run it:  vcsr serve ${out}  (sets Content-Type: application/wasm)')
}

// run_step executes one external build command, surfacing its output on failure.
fn run_step(label string, cmd string) ! {
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return error('wasm: ${label} step failed:\n${res.output}')
	}
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
  vcsr wasm  <src> [--out DIR]    compile a component src dir → core.wasm (v -cc clang)
  vcsr build <app> [--release]    bundle an app dir → <app>/dist (hashing, br/gz, manifest)
  vcsr serve <dist> [--port N]    serve a built dist/ with the vanilla HTTP server
  vcsr version | help

EXAMPLES:
  vcsr gen   examples/counter/src/counter
  vcsr wasm  examples/counter/src               # → examples/counter/wasm/core.wasm
  vcsr build testdata/dashboard-app --release
  vcsr serve testdata/dashboard-app/dist --port 3000

NOTE: `wasm` compiles a V component to a browser-ABI core.wasm via Path 2
(v -cc clang + wasi-sdk; set WASI_SDK), using the runtime host-owned-DOM backend
(see docs/WASM-PATHS-ANALYSIS.md + examples/counter/wasm). `build` still consumes
prebuilt wasm from <app>/build/. `gen` and `wasm` run fully today.')
}
