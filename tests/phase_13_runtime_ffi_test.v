// Phase 13 — the runtime's `js` FFI substrate (vcsr.runtime, slice 2).
//
// The irreducible host-call layer: hold a host handle and get/set/call/new on
// it, and convert primitives across the boundary. DOM bindings, fetch, etc. are
// libraries on top. Tested against the native mock host (no browser).
//
//   v -enable-globals test tests/phase_13_runtime_ffi_test.v
module main

import vcsr { JsValue, func, global, js_bool, js_null, js_num, js_object, js_str, undefined }

fn test_primitive_roundtrip() {
	assert js_str('hi').str() == 'hi'
	assert js_num(3.5).num() == 3.5
	assert js_bool(true).bool() == true
}

fn test_get_set_on_object() {
	o := js_object()
	o.set('name', js_str('vcsr'))
	assert o.get('name').str() == 'vcsr'
	assert o.get('missing').is_undefined()
}

fn test_global_is_one_shared_object() {
	global().set('answer', js_num(42))
	assert global().get('answer').num() == 42
}

fn test_call_method_with_this_and_args() {
	o := js_object()
	o.set('x', js_num(10))
	o.set('add', func(fn (this JsValue, args []JsValue) JsValue {
		return js_num(this.get('x').num() + args[0].num())
	}))
	assert o.call('add', js_num(5)).num() == 15
}

fn test_func_callback_invokes_and_returns() {
	cb := func(fn (this JsValue, args []JsValue) JsValue {
		return js_str('called with ${args.len}')
	})
	assert cb.invoke(js_num(1), js_num(2)).str() == 'called with 2'
}

fn test_calling_a_missing_method_is_undefined() {
	o := js_object()
	assert o.call('nope').is_undefined()
}

fn test_null_is_distinct_from_undefined() {
	assert js_null().is_null()
	assert !js_null().is_undefined()
	assert undefined().is_undefined()
	assert !undefined().is_null()
}

fn test_typeof_discriminates() {
	assert js_str('x').typeof() == 'string'
	assert js_num(1).typeof() == 'number'
	assert js_bool(true).typeof() == 'boolean'
	assert js_object().typeof() == 'object'
	assert js_null().typeof() == 'object' // JS quirk: typeof null === 'object'
	assert undefined().typeof() == 'undefined'
	assert func(fn (this JsValue, args []JsValue) JsValue {
		return undefined()
	}).typeof() == 'function'
}

fn test_new_binds_a_fresh_this_object() {
	ctor := func(fn (this JsValue, args []JsValue) JsValue {
		this.set('label', args[0])
		return undefined() // no explicit return → the fresh `this` is returned
	})
	inst := ctor.new(js_str('made'))
	assert inst.typeof() == 'object'
	assert inst.get('label').str() == 'made'
}

fn test_release_frees_and_reuses_the_slot() {
	a := js_str('temp')
	h := a.handle
	a.release()
	b := js_str('reused') // js_alloc should pop the freed slot rather than grow
	assert b.handle == h
	assert b.str() == 'reused'
}

