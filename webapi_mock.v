// The synchronous Web-API host graph — a LIBRARY on top of the `js` FFI substrate.
//
// DESIGN.md §1: the FFI (js_ffi.v) is the one irreducible host-call layer;
// "everything else (DOM bindings, fetch, reactivity, components) is a library on
// top." This file is that library for the SYNCHRONOUS browser resources catalogued
// in docs/WASM-PATHS-ANALYSIS.md §5 — the ones that need no event loop:
//
//   localStorage / sessionStorage · console · URL · location · history · crypto
//
// `install_webapi()` attaches them to the mock `global()` as a faithful object
// graph, so V code written against the generic FFI runs and is TESTABLE without a
// browser — e.g. `global().get('localStorage').call('getItem', key)`,
// `global().get('history').call('pushState', state, title, url)`. On the
// wasm/browser target these same well-known names resolve to the real page globals
// through `global()`; the V code is identical (see docs/WEB-API-SUPPORT.md).
//
// SCOPE: synchronous only. fetch / setTimeout / WebSocket / IndexedDB are async —
// they need a host-deferred callback dispatcher the native mock cannot model (the
// FFI runs every callback inline; see js_ffi.v). Those stay unsupported here by
// design, not omission. crypto.getRandomValues is modelled over an array-like
// JsObject (`js_array`) since the mock has no typed-array cell; the bytes come
// from a deterministic PRNG (a real host uses crypto) so tests are reproducible.
//
// Build with -enable-globals (the backing state is global, like the effect stack).
module vcsr

__global (
	webapi_console_log []string // captured console output, for assertions
	webapi_rng         u64 // deterministic PRNG state for the crypto mock
)

// install_webapi attaches (and RESETS) the synchronous Web-API globals on the mock
// host. Call once at startup on the native backend; calling again wipes the mock
// host state (fresh localStorage, cleared console buffer, reseeded PRNG), which is
// what test setup wants. On the wasm target the page already provides these, so
// this is a native-backend convenience only.
pub fn install_webapi() {
	js_ensure()
	webapi_console_log = []
	webapi_rng = u64(0x2545F4914F6CDD1D)
	g := global()
	g.set('localStorage', new_storage())
	g.set('sessionStorage', new_storage())
	g.set('console', new_console())
	g.set('URL', func(url_ctor))
	g.set('location', new_location())
	g.set('history', new_history())
	g.set('crypto', new_crypto())
}

// webapi_console_output returns everything written to the mock console, in order.
pub fn webapi_console_output() []string {
	return webapi_console_log
}

// js_array builds an array-like host object (`length` + numeric-index props),
// the shape crypto.getRandomValues fills. The mock has no typed-array cell, so a
// JsObject with string-keyed numeric indices stands in for a Uint8Array.
pub fn js_array(len int) JsValue {
	a := js_object()
	a.set('length', js_num(f64(len)))
	for i in 0 .. len {
		a.set(i.str(), js_num(0))
	}
	return a
}

// --- localStorage / sessionStorage ------------------------------------------

// new_storage builds a Storage object: getItem/setItem/removeItem/clear over a
// private `__store` child object. Two independent instances back localStorage and
// sessionStorage, exactly like the browser's separate areas.
fn new_storage() JsValue {
	s := js_object()
	s.set('__store', js_object())
	s.set('getItem', func(storage_get_item))
	s.set('setItem', func(storage_set_item))
	s.set('removeItem', func(storage_remove_item))
	s.set('clear', func(storage_clear))
	return s
}

fn storage_get_item(this JsValue, args []JsValue) JsValue {
	if args.len == 0 {
		return js_null()
	}
	v := this.get('__store').get(args[0].str())
	return if v.is_undefined() { js_null() } else { v } // missing key → null, per spec
}

fn storage_set_item(this JsValue, args []JsValue) JsValue {
	if args.len < 2 {
		return undefined()
	}
	this.get('__store').set(args[0].str(), js_str(args[1].str()))
	return undefined()
}

fn storage_remove_item(this JsValue, args []JsValue) JsValue {
	if args.len == 0 {
		return undefined()
	}
	this.get('__store').set(args[0].str(), undefined()) // undefined slot reads back as missing → null
	return undefined()
}

fn storage_clear(this JsValue, _ []JsValue) JsValue {
	this.set('__store', js_object())
	return undefined()
}

// --- console -----------------------------------------------------------------

fn new_console() JsValue {
	c := js_object()
	c.set('log', func(console_write))
	c.set('warn', func(console_write))
	c.set('error', func(console_write))
	return c
}

fn console_write(_ JsValue, args []JsValue) JsValue {
	mut parts := []string{cap: args.len}
	for a in args {
		parts << webapi_display(a)
	}
	webapi_console_log << parts.join(' ')
	return undefined()
}

// webapi_display stringifies any host value for console output (the FFI's .str()
// is lossy on non-strings, so discriminate on typeof first).
fn webapi_display(v JsValue) string {
	return match v.typeof() {
		'string' { v.str() }
		'number' { format_number(v.num()) }
		'boolean' { v.bool().str() }
		'undefined' { 'undefined' }
		else { '[object]' }
	}
}

// format_number renders a whole-number f64 without the `.0` (so 42 prints `42`,
// matching JS), and non-integers as-is.
fn format_number(n f64) string {
	return if n == f64(i64(n)) { i64(n).str() } else { n.str() }
}

// --- URL ---------------------------------------------------------------------

// url_ctor is the URL constructor: `URL.new(js_str('https://h/p?q#f'))` returns an
// object exposing href/protocol/host/hostname/pathname/search/hash. A minimal but
// faithful parse — enough for routing and link handling.
fn url_ctor(this JsValue, args []JsValue) JsValue {
	raw := if args.len > 0 { args[0].str() } else { '' }
	this.set('href', js_str(raw))
	mut rest := raw
	mut protocol := ''
	mut host := ''
	if idx := rest.index('://') {
		protocol = rest[..idx + 1] // include the ':'
		rest = rest[idx + 3..]
		mut hi := rest.len
		for sep in ['/', '?', '#'] {
			if p := rest.index(sep) {
				if p < hi {
					hi = p
				}
			}
		}
		host = rest[..hi]
		rest = rest[hi..]
	}
	pathname, search, hash := split_path(rest)
	this.set('protocol', js_str(protocol))
	this.set('host', js_str(host))
	this.set('hostname', js_str(host.all_before(':')))
	this.set('pathname', js_str(pathname))
	this.set('search', js_str(search))
	this.set('hash', js_str(hash))
	return undefined() // `new` returns the fresh `this` with the props above
}

// split_path slices a `path?search#hash` tail into its three parts; an empty path
// becomes '/'. Shared by url_ctor and history navigation.
fn split_path(s string) (string, string, string) {
	mut rest := s
	mut hash := ''
	mut search := ''
	if hp := rest.index('#') {
		hash = rest[hp..]
		rest = rest[..hp]
	}
	if sp := rest.index('?') {
		search = rest[sp..]
		rest = rest[..sp]
	}
	pathname := if rest == '' { '/' } else { rest }
	return pathname, search, hash
}

// --- location ----------------------------------------------------------------

fn new_location() JsValue {
	loc := js_object()
	loc.set('href', js_str('http://localhost/'))
	loc.set('protocol', js_str('http:'))
	loc.set('host', js_str('localhost'))
	loc.set('hostname', js_str('localhost'))
	loc.set('pathname', js_str('/'))
	loc.set('search', js_str(''))
	loc.set('hash', js_str(''))
	return loc
}

// --- history -----------------------------------------------------------------

fn new_history() JsValue {
	h := js_object()
	h.set('pushState', func(history_push))
	h.set('replaceState', func(history_push))
	return h
}

// history_push mirrors history.pushState(state, title, url): it updates the mock
// location's href/pathname/search/hash from `url` (which may be relative), exactly
// as the browser does — so a router reading `location.pathname` after a push sees
// the new route.
fn history_push(_ JsValue, args []JsValue) JsValue {
	if args.len < 3 {
		return undefined()
	}
	url := args[2].str()
	if url == '' {
		return undefined()
	}
	loc := global().get('location')
	loc.set('href', js_str(url))
	mut path := url
	if idx := path.index('://') { // absolute URL → drop scheme+host, keep the path on
		after := path[idx + 3..]
		path = if p := after.index('/') { after[p..] } else { '/' }
	}
	pathname, search, hash := split_path(path)
	loc.set('pathname', js_str(pathname))
	loc.set('search', js_str(search))
	loc.set('hash', js_str(hash))
	return undefined()
}

// --- crypto ------------------------------------------------------------------

fn new_crypto() JsValue {
	c := js_object()
	c.set('getRandomValues', func(crypto_get_random_values))
	return c
}

// crypto_get_random_values fills an array-like (from js_array) with bytes and
// returns it — like the real API, which fills in place and returns the same array.
// Bytes come from a deterministic xorshift PRNG (a real host uses CSPRNG entropy).
fn crypto_get_random_values(_ JsValue, args []JsValue) JsValue {
	if args.len == 0 {
		return undefined()
	}
	arr := args[0]
	n := int(arr.get('length').num())
	for i in 0 .. n {
		arr.set(i.str(), js_num(f64(webapi_next_byte())))
	}
	return arr
}

fn webapi_next_byte() u8 {
	mut x := webapi_rng
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	webapi_rng = x
	return u8(x & 0xFF)
}
