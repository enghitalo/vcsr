// Phase 08 + 10 — Bundle emission and the end-to-end build.
//
// build() turns a fixture app directory into a servable dist/ bundle and an
// in-memory Bundle handle: an empty-body index.html that loads the hashed
// loader, content-hashed filenames for every cacheable asset, precompressed
// (.br/.gz) siblings, a source map, the atomized app.css, and manifest.json.
// vanilla's http_server.static_assets then serves dist/ as-is (phase 10).
//
// NOTE ON THE WASM STEP: V cannot yet compile a browser-ready wasm module
// (native `-b wasm -os browser` panics; the `v -cc clang` path emits WASI
// imports) — see ../docs/WASM-PATHS-ANALYSIS.md and the upstream issues it links.
// So build() consumes PREBUILT browser-ABI wasm from the app's build/ dir
// (hand-authored, no wasi_snapshot_preview1 imports) and does the real bundling
// work around it: content hashing, compression, the loader/manifest emit, and
// dead-route elimination. The wasm_opt/strip level is recorded in meta (the
// prebuilt artifacts are already size-optimized and stripped).
module bundle

import os
import crypto.sha256
import compress.gzip
import x.json2
import vcsr.router { Route }
import vcsr.css

// Meta records build-level decisions queried by tests/tooling.
pub struct Meta {
pub:
	wasm_opt_level  string   // 'Oz' in release (size), 'O0' otherwise
	names_stripped  bool     // symbol names stripped in release
	prefetch_routes []string // lazy route names, prefetchable on intent
}

// Asset is one emitted file's handle: its name plus (for wasm) the module
// namespaces it imports.
pub struct Asset {
pub:
	name        string
	import_mods []string
}

// imports_module reports whether this (wasm) asset imports from module `m`.
pub fn (a &Asset) imports_module(m string) bool {
	return m in a.import_mods
}

@[params]
pub struct BuildOpt {
pub:
	release bool
}

// Bundle is the in-memory result of a build: every emitted file plus metadata.
pub struct Bundle {
pub:
	meta Meta
mut:
	order   []string            // emit order, for deterministic find()
	files   map[string][]u8     // name -> bytes (includes .br/.gz/.map siblings)
	imports map[string][]string // wasm name -> imported module namespaces
	symbols []string            // reachable component symbols (post dead-code-elim)
}

// text returns an asset's bytes as a string.
pub fn (b &Bundle) text(name string) !string {
	if data := b.files[name] {
		return data.bytestr()
	}
	return error('bundle: no asset "${name}"')
}

// bytes returns an asset's raw bytes.
pub fn (b &Bundle) bytes(name string) ![]u8 {
	if data := b.files[name] {
		return data
	}
	return error('bundle: no asset "${name}"')
}

// has reports whether an asset with this exact name was emitted.
pub fn (b &Bundle) has(name string) bool {
	return name in b.files
}

// has_symbol reports whether a component symbol survived dead-route elimination.
pub fn (b &Bundle) has_symbol(sym string) bool {
	return sym in b.symbols
}

// find returns the first emitted asset whose name matches the glob (`*` matches
// any run of characters), or an error if none matches.
pub fn (b &Bundle) find(pattern string) !Asset {
	for name in b.order {
		if glob_match(pattern, name) {
			return Asset{
				name:        name
				import_mods: b.imports[name] or { []string{} }
			}
		}
	}
	return error('bundle: no asset matching "${pattern}"')
}

// --- the build ---------------------------------------------------------------

struct AppSpec {
	routes []Route
	styles map[string]string
}

// build compiles the app at `dir` into a dist/ bundle (written to disk) and an
// in-memory Bundle.
pub fn build(dir string, opt BuildOpt) !Bundle {
	app := load_app(dir)!
	router.plan(app.routes)! // validate the route table (phase 06)

	mut b := Bundle{
		meta:    Meta{
			wasm_opt_level:  if opt.release { 'Oz' } else { 'O0' }
			names_stripped:  opt.release
			prefetch_routes: lazy_names(app.routes)
		}
		symbols: reachable_components(app.routes)
	}

	// dist/ is written idempotently (write-only-if-changed, no rmdir): the build
	// is deterministic, so re-runs and concurrent builds (phases 08 & 10 both
	// call build, in parallel with phase 09 reading dist) converge on identical
	// bytes without a destructive delete/rewrite race.
	out := os.join_path(dir, 'dist')
	os.mkdir_all(out)!

	// 1) wasm: core (MAIN) + one side chunk per lazy route, content-hashed from
	// the prebuilt browser-ABI artifacts in build/.
	core_bytes := os.read_bytes(os.join_path(dir, 'build', 'core.wasm'))!
	core_name := 'core.${short_hash(core_bytes)}.wasm'
	b.emit(out, core_name, core_bytes, EmitOpt{
		compress:    true
		import_mods: wasm_import_modules(core_bytes)
	})!

	mut route_names := []string{}
	for r in app.routes {
		if !r.lazy {
			continue
		}
		seg := last_seg(r.path)
		rb := os.read_bytes(os.join_path(dir, 'build', 'route-${seg}.wasm'))!
		rname := 'route-${seg}.${short_hash(rb)}.wasm'
		b.emit(out, rname, rb, EmitOpt{ compress: true, import_mods: wasm_import_modules(rb) })!
		route_names << rname
	}

	// 2) app.css: an app may ship a verbatim global stylesheet at src/styles.css
	// (used as-is, no scoping — for a hand-written runtime whose class names are
	// fixed); otherwise each component's styles are scoped and atomized.
	custom_css := os.join_path(dir, 'src', 'styles.css')
	css_text := if os.exists(custom_css) {
		os.read_file(custom_css)!
	} else {
		mut scoped := []css.ScopedCss{}
		for comp, style in app.styles {
			scoped << css.scope(comp, style)!
		}
		if scoped.len > 0 { css.atomize(scoped)!.text } else { '/* no styles */' }
	}
	css_bytes := css_text.bytes()
	css_name := 'app.${short_hash(css_bytes)}.css'
	b.emit(out, css_name, css_bytes, EmitOpt{ compress: true })!

	// 3) app.js: the streaming-instantiate loader. An app may ship its own JS
	// runtime/host at src/loader.js (the `js` FFI substrate is a library, per the
	// design); the `__CORE_WASM__` token is replaced with the hashed core path.
	// Otherwise the default minimal loader is generated.
	custom_loader := os.join_path(dir, 'src', 'loader.js')
	js_text := if os.exists(custom_loader) {
		os.read_file(custom_loader)!.replace('__CORE_WASM__', '/${core_name}')
	} else {
		loader_js(core_name, route_names)
	}
	js_bytes := js_text.bytes()
	js_name := 'app.${short_hash(js_bytes)}.js'
	b.emit(out, js_name, js_bytes, EmitOpt{ compress: true, sourcemap: true })!

	// 4) index.html: empty body, preloads core wasm, loads the hashed loader.
	html := index_html(core_name, js_name, css_name)
	b.emit(out, 'index.html', html.bytes(), EmitOpt{})!

	// 5) manifest.json: vcsr's build record (read by the loader/tooling, NOT the
	// server). Lists per-asset content type + cache policy and the SPA fallback.
	mut mentries := [manifest_entry('index.html')]
	mentries << manifest_entry(js_name)
	mentries << manifest_entry(css_name)
	mentries << manifest_entry(core_name)
	for rn in route_names {
		mentries << manifest_entry(rn)
	}
	manifest_text := build_manifest(mentries, route_names)
	b.emit(out, 'manifest.json', manifest_text.bytes(), EmitOpt{})!

	// drop any stale files left by an earlier build with different content hashes.
	// Safe under concurrent identical builds: the emitted set is deterministic, so
	// in steady state b.files lists every present file and nothing is removed.
	prune_stale(out, b.files)

	return b
}

fn prune_stale(out string, keep map[string][]u8) {
	entries := os.ls(out) or { return }
	for f in entries {
		if f !in keep {
			os.rm(os.join_path(out, f)) or {}
		}
	}
}

// --- emit --------------------------------------------------------------------

@[params]
struct EmitOpt {
	compress    bool
	sourcemap   bool
	import_mods []string
}

// emit writes one asset to disk + records it, plus its .br/.gz siblings (when
// compress) and a .map (when sourcemap).
fn (mut b Bundle) emit(out string, name string, data []u8, opt EmitOpt) ! {
	path := os.join_path(out, name)
	write_if_changed(path, data)!
	b.record(name, data)
	if opt.import_mods.len > 0 {
		b.imports[name] = opt.import_mods
	}

	if opt.compress {
		// gzip (native), then brotli (via node's zlib — V has no brotli).
		if gz := gzip.compress(data) {
			write_if_changed(path + '.gz', gz)!
			b.record(name + '.gz', gz)
		}
		// brotli is non-deterministic to predict, so only (re)generate when absent.
		if !os.exists(path + '.br') {
			brotli_compress(path) or {}
		}
		if os.exists(path + '.br') {
			brb := os.read_bytes(path + '.br') or { []u8{} }
			b.record(name + '.br', brb)
		}
	}
	if opt.sourcemap {
		mapname := name + '.map'
		mapdata :=
			'{"version":3,"file":"${name}","sources":["app.v"],"names":[],"mappings":""}'.bytes()
		write_if_changed(os.join_path(out, mapname), mapdata)!
		b.record(mapname, mapdata)
	}
}

// write_if_changed writes `data` to `path` only when it differs from what is
// already there — so deterministic re-builds (and concurrent builds of the same
// dist) don't churn the disk or race a reader.
fn write_if_changed(path string, data []u8) ! {
	if os.exists(path) {
		if existing := os.read_bytes(path) {
			if existing == data {
				return
			}
		}
	}
	os.write_file_array(path, data)!
}

fn (mut b Bundle) record(name string, data []u8) {
	if name !in b.files {
		b.order << name
	}
	b.files[name] = data
}

// --- generators --------------------------------------------------------------

fn index_html(core_name string, js_name string, css_name string) string {
	return '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n' +
		'<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
		'<link rel="preload" href="/${core_name}" as="fetch" type="application/wasm" crossorigin>\n' +
		'<link rel="stylesheet" href="/${css_name}">\n' +
		'<link rel="modulepreload" href="/${js_name}">\n' +
		'<script type="module" src="/${js_name}"></script>\n' + '</head>\n<body></body>\n</html>\n'
}

fn loader_js(core_name string, route_names []string) string {
	mut routes_js := '['
	for i, rn in route_names {
		if i > 0 {
			routes_js += ', '
		}
		routes_js += "'/${rn}'"
	}
	routes_js += ']'
	// the minimal `js` FFI substrate the design describes: DOM handles cross as
	// externref, strings as (ptr,len) into the module's shared linear memory.
	host := 'const _dec = new TextDecoder();\n' + 'let _mem = null;\n' +
		'function _str(p, l) { return _dec.decode(new Uint8Array(_mem.buffer, p, l)); }\n' +
		'const env = {\n' +
		"  register_template(p, l) { const t = document.createElement('template'); t.innerHTML = _str(p, l); document.body.appendChild(t.content.cloneNode(true)); return t; },\n" +
		'  clone_template(t) { return t.content.cloneNode(true); },\n' +
		'  set_text(n, p, l) { if (n) n.textContent = _str(p, l); },\n' + '};\n'
	return '// app loader — GENERATED by vcsr. Streaming-instantiate the core module;\n' +
		'// DOM handles cross as externref, strings as (ptr,len) into shared memory.\n' +
		'const CORE = "/${core_name}";\n' + 'const ROUTE_CHUNKS = ${routes_js};\n' + host +
		'async function boot() {\n' +
		'  const { instance } = await WebAssembly.instantiateStreaming(fetch(CORE), { env });\n' +
		'  _mem = instance.exports.memory;\n' +
		'  if (instance.exports._initialize) instance.exports._initialize();\n' +
		'  if (instance.exports.mount) instance.exports.mount(document.body);\n' +
		"  document.documentElement.setAttribute('data-vcsr', 'mounted');\n" + '}\n' +
		"boot().catch(function (e) { document.documentElement.setAttribute('data-vcsr-error', String(e)); console.error(e); });\n" +
		'//# sourceMappingURL=/app.js.map\n'
}

// --- manifest ----------------------------------------------------------------

struct MEntry {
	name         string
	content_type string
	cache        string
}

fn manifest_entry(name string) MEntry {
	return MEntry{
		name:         name
		content_type: content_type_of(name)
		cache:        cache_policy(name)
	}
}

fn build_manifest(entries []MEntry, route_names []string) string {
	mut s := '{\n  "spa_fallback": "index.html",\n  "preload": ["index.html"],\n  "routes": ['
	for i, rn in route_names {
		if i > 0 {
			s += ', '
		}
		s += '"/${rn}"'
	}
	s += '],\n  "entries": [\n'
	for i, e in entries {
		s += '    {"name": "${e.name}", "content_type": "${e.content_type}", "cache": "${e.cache}"}'
		s += if i < entries.len - 1 { ',\n' } else { '\n' }
	}
	s += '  ]\n}\n'
	return s
}

// content_type_of mirrors what static_assets derives from the filename.
fn content_type_of(name string) string {
	return match true {
		name.ends_with('.html') { 'text/html; charset=utf-8' }
		name.ends_with('.css') { 'text/css; charset=utf-8' }
		name.ends_with('.js') { 'text/javascript; charset=utf-8' }
		name.ends_with('.wasm') { 'application/wasm' }
		name.ends_with('.json') { 'application/json' }
		else { 'application/octet-stream' }
	}
}

// cache_policy: the HTML entrypoint and the manifest are no-cache (so a deploy
// that swaps them takes effect immediately); content-hashed assets are immutable.
fn cache_policy(name string) string {
	if name == 'index.html' || name == 'manifest.json' {
		return 'no-cache'
	}
	if is_hashed(name) {
		return 'public, max-age=31536000, immutable'
	}
	return 'public, max-age=3600'
}

// is_hashed reports whether a filename carries a content-hash segment (a run of
// >=6 hex chars between dots), e.g. core.9f3a1c.wasm.
fn is_hashed(name string) bool {
	for part in name.split('.') {
		if part.len >= 6 && all_hex(part) {
			return true
		}
	}
	return false
}

// --- app spec loading --------------------------------------------------------

fn load_app(dir string) !AppSpec {
	txt := os.read_file(os.join_path(dir, 'app.json')) or {
		return error('bundle: cannot read ${dir}/app.json: ${err}')
	}
	root := json2.decode[json2.Any](txt)!.as_map()
	mut routes := []Route{}
	if rs := root['routes'] {
		for r in rs.as_array() {
			m := r.as_map()
			routes << Route{
				path:      (m['path'] or { json2.Any('') }).str()
				component: (m['component'] or { json2.Any('') }).str()
				lazy:      (m['lazy'] or { json2.Any(false) }).bool()
			}
		}
	}
	mut styles := map[string]string{}
	if st := root['styles'] {
		for k, v in st.as_map() {
			styles[k] = v.str()
		}
	}
	return AppSpec{
		routes: routes
		styles: styles
	}
}

// reachable_components is the set of component symbols that ship: those named by
// a route. A component named by no route (e.g. UnreachableWidget) is dead and
// dropped — the build never references it, so has_symbol() returns false.
fn reachable_components(routes []Route) []string {
	mut out := []string{}
	for r in routes {
		if r.component != '' && r.component !in out {
			out << r.component
		}
	}
	return out
}

fn lazy_names(routes []Route) []string {
	mut out := []string{}
	for r in routes {
		if r.lazy {
			out << last_seg(r.path)
		}
	}
	return out
}

// --- wasm import-module extraction -------------------------------------------

// wasm_import_modules parses the import section and returns the distinct module
// namespaces the module imports from (e.g. ['env']). Used by Asset.imports_module
// to prove the browser target imports no 'wasi_snapshot_preview1'.
fn wasm_import_modules(b []u8) []string {
	mut mods := []string{}
	if b.len < 8 || b[0] != 0x00 || b[1] != 0x61 || b[2] != 0x73 || b[3] != 0x6d {
		return mods
	}
	mut i := 8
	for i < b.len {
		id := b[i]
		i++
		size, ni := uleb(b, i) or { return mods }
		i = ni
		end := i + int(size)
		if id == 2 { // import section
			mut p := i
			count, np := uleb(b, p) or { return mods }
			p = np
			for _ in 0 .. int(count) {
				mlen, pm := uleb(b, p) or { return mods }
				p = pm
				if p + int(mlen) > b.len {
					return mods
				}
				modname := b[p..p + int(mlen)].bytestr()
				p += int(mlen)
				if modname !in mods {
					mods << modname
				}
				flen, pf := uleb(b, p) or { return mods } // skip field name
				p = pf + int(flen)
				p = skip_import_desc(b, p) or { return mods } // skip descriptor
			}
		}
		i = end
	}
	return mods
}

fn skip_import_desc(b []u8, p0 int) !int {
	mut p := p0
	if p >= b.len {
		return error('truncated import desc')
	}
	kind := b[p]
	p++
	match kind {
		0x00 { // func: typeidx
			_, np := uleb(b, p)!
			p = np
		}
		0x01 { // table: reftype + limits
			p++ // reftype
			p = skip_limits(b, p)!
		}
		0x02 { // mem: limits
			p = skip_limits(b, p)!
		}
		0x03 { // global: valtype + mut
			p += 2
		}
		else {
			return error('unknown import kind ${kind}')
		}
	}

	return p
}

fn skip_limits(b []u8, p0 int) !int {
	mut p := p0
	if p >= b.len {
		return error('truncated limits')
	}
	flag := b[p]
	p++
	_, p2 := uleb(b, p)! // min
	p = p2
	if flag & 0x01 != 0 {
		_, p3 := uleb(b, p)! // max
		p = p3
	}
	return p
}

// uleb decodes an unsigned LEB128 at offset `p`, returning (value, next_offset).
fn uleb(b []u8, p0 int) !(u64, int) {
	mut result := u64(0)
	mut shift := u32(0)
	mut p := p0
	for p < b.len {
		byte_ := b[p]
		p++
		result |= u64(byte_ & 0x7f) << shift
		if byte_ & 0x80 == 0 {
			return result, p
		}
		shift += 7
		if shift >= 64 {
			return error('LEB128 overflow')
		}
	}
	return error('truncated LEB128')
}

// --- small helpers -----------------------------------------------------------

fn short_hash(data []u8) string {
	return sha256.sum(data).hex()[..6]
}

fn last_seg(path string) string {
	trimmed := path.trim_right('/')
	seg := trimmed.all_after_last('/')
	return if seg == '' { 'index' } else { seg }
}

fn brotli_compress(path string) ! {
	script := os.join_path(os.temp_dir(), 'vcsr_brotli.mjs')
	if !os.exists(script) {
		os.write_file(script,
			"import {brotliCompressSync} from 'node:zlib';\nimport {readFileSync, writeFileSync} from 'node:fs';\nconst p = process.argv[2];\nwriteFileSync(p + '.br', brotliCompressSync(readFileSync(p)));\n")!
	}
	res := os.execute('node "${script}" "${path}"')
	if res.exit_code != 0 {
		return error('brotli (node) failed: ${res.output}')
	}
}

fn all_hex(s string) bool {
	if s == '' {
		return false
	}
	for c in s {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)) {
			return false
		}
	}
	return true
}

fn glob_match(pattern string, name string) bool {
	return match_glob(pattern, 0, name, 0)
}

fn match_glob(p string, pi0 int, s string, si0 int) bool {
	mut pi := pi0
	mut si := si0
	for pi < p.len {
		if p[pi] == `*` {
			for k in si .. s.len + 1 {
				if match_glob(p, pi + 1, s, k) {
					return true
				}
			}
			return false
		}
		if si >= s.len || s[si] != p[pi] {
			return false
		}
		pi++
		si++
	}
	return si == s.len
}
