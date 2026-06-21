// Phase 16 — the synchronous Web-API host graph (vcsr, webapi_mock.v).
//
// The sync resources from docs/WASM-PATHS-ANALYSIS.md §5 — localStorage,
// sessionStorage, console, URL, location, history, crypto — reached through the
// generic `js` FFI exactly as a browser would, but against the native mock so
// they are testable without one. (Async resources — fetch/timers/sockets/IDB —
// are out of scope: the mock can't model a host-deferred callback.)
//
//   v -enable-globals test tests/phase_16_runtime_webapi_test.v
module main

import vcsr { global, install_webapi, js_array, js_num, js_str, undefined, webapi_console_output }

fn test_local_storage_roundtrip() {
	install_webapi()
	ls := global().get('localStorage')
	assert ls.call('getItem', js_str('missing')).is_null() // absent key → null, not undefined
	ls.call('setItem', js_str('theme'), js_str('dark'))
	assert ls.call('getItem', js_str('theme')).str() == 'dark'
	ls.call('removeItem', js_str('theme'))
	assert ls.call('getItem', js_str('theme')).is_null()
}

fn test_local_storage_clear() {
	install_webapi()
	ls := global().get('localStorage')
	ls.call('setItem', js_str('a'), js_str('1'))
	ls.call('setItem', js_str('b'), js_str('2'))
	ls.call('clear')
	assert ls.call('getItem', js_str('a')).is_null()
	assert ls.call('getItem', js_str('b')).is_null()
}

fn test_session_and_local_storage_are_independent() {
	install_webapi()
	global().get('localStorage').call('setItem', js_str('k'), js_str('L'))
	global().get('sessionStorage').call('setItem', js_str('k'), js_str('S'))
	assert global().get('localStorage').get('__store').get('k').str() == 'L'
	assert global().get('sessionStorage').call('getItem', js_str('k')).str() == 'S'
	// the local value is untouched by the session write
	assert global().get('localStorage').call('getItem', js_str('k')).str() == 'L'
}

fn test_console_captures_mixed_args() {
	install_webapi()
	con := global().get('console')
	con.call('log', js_str('count'), js_num(42))
	con.call('error', js_str('boom'))
	out := webapi_console_output()
	assert out.len == 2
	assert out[0] == 'count 42' // numbers stringify, not lost to ''
	assert out[1] == 'boom'
}

fn test_url_parses_components() {
	install_webapi()
	u := global().get('URL').new(js_str('https://example.com:8080/reports?id=7#top'))
	assert u.get('protocol').str() == 'https:'
	assert u.get('host').str() == 'example.com:8080'
	assert u.get('hostname').str() == 'example.com'
	assert u.get('pathname').str() == '/reports'
	assert u.get('search').str() == '?id=7'
	assert u.get('hash').str() == '#top'
	assert u.get('href').str() == 'https://example.com:8080/reports?id=7#top'
}

fn test_history_pushstate_updates_location() {
	install_webapi()
	loc := global().get('location')
	assert loc.get('pathname').str() == '/' // default landing
	global().get('history').call('pushState', undefined(), js_str(''), js_str('/reports?id=7#row'))
	// the SAME location object reflects the navigation, as in the browser
	assert global().get('location').get('pathname').str() == '/reports'
	assert global().get('location').get('search').str() == '?id=7'
	assert global().get('location').get('hash').str() == '#row'
}

fn test_history_pushstate_strips_origin_for_absolute_url() {
	install_webapi()
	global().get('history').call('pushState', undefined(), js_str(''),
		js_str('http://localhost/todos'))
	assert global().get('location').get('pathname').str() == '/todos'
}

fn test_crypto_fills_array_with_bytes() {
	install_webapi()
	buf := js_array(16)
	ret := global().get('crypto').call('getRandomValues', buf)
	// fills in place AND returns the same array (length preserved)
	assert int(ret.get('length').num()) == 16
	mut nonzero := 0
	for i in 0 .. 16 {
		b := buf.get(i.str()).num()
		assert b >= 0 && b <= 255 // valid byte range
		if b != 0 {
			nonzero++
		}
	}
	assert nonzero > 0 // it actually wrote entropy, not all zeros
}

fn test_install_resets_mock_state() {
	install_webapi()
	global().get('localStorage').call('setItem', js_str('k'), js_str('v'))
	global().get('console').call('log', js_str('first'))
	install_webapi() // a fresh install wipes storage + console buffer
	assert global().get('localStorage').call('getItem', js_str('k')).is_null()
	assert webapi_console_output().len == 0
}
