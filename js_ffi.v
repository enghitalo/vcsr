// The `js` FFI substrate — the one irreducible host-call layer (DESIGN.md §1).
//
// WebAssembly is a guest: by default it can touch nothing in the page. So the
// toolchain must provide a way to hold a reference to a host (JS) value and
// operate on it — get/set a property, call a method, construct, and convert
// primitives across the boundary. Everything else (DOM bindings, fetch,
// reactivity, components) is a library on top. This maps 1:1 to Go's
// `syscall/js.Value`.
//
// A `JsValue` is an OPAQUE HANDLE. On the wasm/browser target it is lowered to
// an `externref` (or an integer index into a host-side table — the portable
// bridge, see docs/WASM-ABI.md, whose allocate/lookup/FREE protocol `release()`
// mirrors). Here we provide the NATIVE backend: a pure-V mock host (a small
// JS-like object graph) so the substrate — and everything built on it — is
// testable without a browser. The wasm backend is the same surface with the
// operations imported instead of interpreted.
//
// Uses a global host table (single-threaded guest); build with -enable-globals.
//
// Mock-vs-host notes (kept faithful so code written here works on wasm too):
//  - `.str()/.num()/.bool()` are LOSSY on a type mismatch (return ''/0/false),
//    matching a permissive host read; use `typeof()` to discriminate.
//  - callbacks receive `args` as a variable-length slice; a callback MUST
//    bounds-check (a host call with fewer args gives JS `undefined`, not a fault).
module vcsr

// JsValue is an opaque handle to a host value. Copying it copies the handle, so
// it crosses into closures (V captures by value) while still naming the same
// host value — like an externref.
pub struct JsValue {
pub:
	handle int
}

// JsCallback is a V function exposed to the host (an event listener, a promise
// continuation). `this` is the host receiver; `args` are the call arguments.
pub type JsCallback = fn (this JsValue, args []JsValue) JsValue

// A host object: string-keyed properties, each a handle to another value.
struct JsObject {
mut:
	props map[string]int
}

// the empty value and the explicit null — distinct, like JS undefined vs null.
struct JsUndefined {}

struct JsNull {}

// One cell in the host table.
type JsCell = JsCallback | JsNull | JsObject | JsUndefined | bool | f64 | string

__global (
	js_cells []JsCell
	js_free  []int // handles freed by release(), reused by js_alloc (no leak)
)

// well-known handles, created on first use
const js_h_undefined = 0
const js_h_null = 1
const js_h_global = 2

fn js_ensure() {
	if js_cells.len == 0 {
		js_cells << JsUndefined{} // 0
		js_cells << JsNull{}      // 1
		js_cells << JsObject{
			props: map[string]int{}
		} // 2: the global object
	}
}

fn js_alloc(c JsCell) int {
	js_ensure()
	if js_free.len > 0 {
		h := js_free.pop()
		js_cells[h] = c
		return h
	}
	js_cells << c
	return js_cells.len - 1
}

// undefined is the empty host value (also what missing props/returns give).
pub fn undefined() JsValue {
	js_ensure()
	return JsValue{
		handle: js_h_undefined
	}
}

// js_null is the explicit host null (distinct from undefined: `document.querySelector`
// misses, `fetch` JSON nulls, etc. are null, not undefined).
pub fn js_null() JsValue {
	js_ensure()
	return JsValue{
		handle: js_h_null
	}
}

// global returns the host global object (the page's `globalThis`).
pub fn global() JsValue {
	js_ensure()
	return JsValue{
		handle: js_h_global
	}
}

// release frees a handle so its table slot can be reused — the FREE half of the
// handle-table protocol (docs/WASM-ABI.md). A re-rendering app must release the
// handles (strings, callbacks, cloned nodes) it stops using, or the table grows
// without bound. The well-known handles (undefined/null/global) are never freed.
pub fn (v JsValue) release() {
	if v.handle <= js_h_global || v.handle >= js_cells.len {
		return
	}
	js_cells[v.handle] = JsUndefined{}
	js_free << v.handle
}

// --- V → JsValue (cross a primitive into the host) --------------------------

pub fn js_str(s string) JsValue {
	return JsValue{
		handle: js_alloc(s)
	}
}

pub fn js_num(n f64) JsValue {
	return JsValue{
		handle: js_alloc(n)
	}
}

pub fn js_bool(b bool) JsValue {
	return JsValue{
		handle: js_alloc(b)
	}
}

// js_object creates a fresh empty host object.
pub fn js_object() JsValue {
	return JsValue{
		handle: js_alloc(JsObject{
			props: map[string]int{}
		})
	}
}

// func exposes a V function to the host (e.g. as an event handler). Invoking it
// from the host (call/new on the property it's stored in) runs `f`.
pub fn func(f JsCallback) JsValue {
	return JsValue{
		handle: js_alloc(JsCallback(f))
	}
}

// --- JsValue → V (read a primitive back out; lossy on type mismatch) --------

pub fn (v JsValue) str() string {
	c := js_cells[v.handle] or { return '' }
	return if c is string { c } else { '' }
}

pub fn (v JsValue) num() f64 {
	c := js_cells[v.handle] or { return 0 }
	return if c is f64 { c } else { 0 }
}

pub fn (v JsValue) bool() bool {
	c := js_cells[v.handle] or { return false }
	return if c is bool { c } else { false }
}

// typeof discriminates a handle (JS `typeof`, with `typeof null === 'object'`).
pub fn (v JsValue) typeof() string {
	c := js_cells[v.handle] or { return 'undefined' }
	return match c {
		JsUndefined { 'undefined' }
		JsNull { 'object' }
		bool { 'boolean' }
		f64 { 'number' }
		string { 'string' }
		JsObject { 'object' }
		JsCallback { 'function' }
	}
}

pub fn (v JsValue) is_undefined() bool {
	return v.handle == js_h_undefined
}

pub fn (v JsValue) is_null() bool {
	return v.handle == js_h_null
}

fn (v JsValue) is_object() bool {
	c := js_cells[v.handle] or { return false }
	return c is JsObject
}

// --- operate on a host value ------------------------------------------------

// get reads a property; missing → undefined.
pub fn (v JsValue) get(prop string) JsValue {
	c := js_cells[v.handle] or { return undefined() }
	if c is JsObject {
		if h := c.props[prop] {
			return JsValue{
				handle: h
			}
		}
	}
	return undefined()
}

// set writes a property (creating it). A no-op on non-objects.
pub fn (v JsValue) set(prop string, val JsValue) {
	mut c := js_cells[v.handle] or { return }
	if mut c is JsObject {
		c.props[prop] = val.handle
		js_cells[v.handle] = c // store back so the write persists regardless of map copy semantics
	}
}

// call invokes method `name` (a function-valued property) with `this` = v.
pub fn (v JsValue) call(name string, args ...JsValue) JsValue {
	target := v.get(name)
	fc := js_cells[target.handle] or { return undefined() }
	if fc is JsCallback {
		return fc(v, args)
	}
	return undefined()
}

// new invokes v as a constructor: a fresh object is bound as `this`, and that
// object is returned unless the constructor explicitly returns an object —
// mirroring JS `new` (and the host's Reflect.construct).
pub fn (v JsValue) new(args ...JsValue) JsValue {
	c := js_cells[v.handle] or { return undefined() }
	if c is JsCallback {
		obj := js_object()
		ret := c(obj, args)
		return if ret.is_object() { ret } else { obj }
	}
	return undefined()
}

// invoke calls v directly (v must be a function), with `this` = undefined.
pub fn (v JsValue) invoke(args ...JsValue) JsValue {
	c := js_cells[v.handle] or { return undefined() }
	if c is JsCallback {
		return c(undefined(), args)
	}
	return undefined()
}
