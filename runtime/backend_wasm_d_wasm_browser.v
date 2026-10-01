// The WASM rendering backend (compiled with -d wasm_browser).
//
// The browser-real counterpart of backend_native_notd_wasm_browser.v: same public
// API (Template.instance / bind_*_ctx / Instance.view / View), but the HOST owns
// the DOM and the template. The V side holds only integer node HANDLES (in arrays)
// and the reactive logic — NO string-keyed maps and NO V template parser, both of
// which fail on wasm (see docs/WASM-PATHS-ANALYSIS.md §2.1). Every DOM mutation is
// an imported (ptr,len)/(handle) FFI call; events come back through the exported
// vcsr_dispatch / vcsr_dispatch_input. Build with -gc none -enable-globals and
// clang -I <repo>/runtime (for vcsr_host.h).
module runtime

import vcsr

#include "vcsr_host.h"

// --- host DOM ABI (imports; see vcsr_host.h) --------------------------------
fn C.host_register_template(html &u8, len int) int
fn C.host_clone(tpl int) int
fn C.host_slot_at(root int, path voidptr, n int) int
fn C.host_anchor_at(node int, k int) int
fn C.host_anchor_text(node int, k int) int
fn C.host_set_text(node int, ptr &u8, len int)
fn C.host_set_attr(node int, np &u8, nl int, vp &u8, vl int)
fn C.host_set_value(node int, ptr &u8, len int)
fn C.host_set_visible(node int, visible int)
fn C.host_on(node int, ev &u8, el int, cb_idx int)
fn C.host_on_input(node int, cb_idx int)
fn C.host_mount(root int, sel &u8, len int)
fn C.host_init(dispatch voidptr, input_ptr voidptr, dispatch_input voidptr)

// Instance is one clone of a template: the host root handle, the resolved slot
// node handles (by element-child path), and the effects its bindings created.
pub struct Instance {
mut:
	root    int
	slots   []int
	descs   []SlotDesc
	effects []&vcsr.Effect
}

// View is the live root (a host handle) plus the effects to dispose on teardown.
pub struct View {
pub:
	root int
mut:
	effects []&vcsr.Effect
}

pub fn (mut v View) dispose() {
	for mut e in v.effects {
		e.dispose()
	}
	v.effects = []
}

// instance registers the skeleton with the host (host parses it — the V parser
// can't run on wasm), clones it, and resolves each slot's node handle by walking
// the element-child path host-side.
pub fn (t Template) instance() Instance {
	init_host()
	tpl := C.host_register_template(t.html.str, t.html.len)
	root := C.host_clone(tpl)
	mut slots := []int{cap: t.slots.len}
	for d in t.slots {
		mut h := C.host_slot_at(root, d.path.data, d.path.len)
		if d.anchor >= 0 {
			// an anchored text slot patches a fresh text node at its anchor
			h = if d.kind == .text {
				C.host_anchor_text(h, d.anchor)
			} else {
				C.host_anchor_at(h, d.anchor)
			}
		}
		slots << h
	}
	return Instance{
		root:  root
		slots: slots
		descs: t.slots.clone()
	}
}

pub fn (mut ins Instance) view() View {
	return View{
		root:    ins.root
		effects: ins.effects
	}
}

// mount_view appends the cloned root into document.querySelector(sel) (the wasm
// app's mount step; App is native-only, so the wasm entry calls this directly).
pub fn mount_view(v View, sel string) {
	C.host_mount(v.root, sel.str, sel.len)
}

// --- closure-free bindings (the codegen target — same API as native) --------

@[heap]
struct TextBind {
	handle int
	ctx    voidptr
	get    fn (ctx voidptr) string = unsafe { nil }
}

fn patch_text(p voidptr) {
	b := unsafe { &TextBind(p) }
	s := b.get(b.ctx)
	C.host_set_text(b.handle, s.str, s.len)
}

pub fn bind_text_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) string) {
	b := &TextBind{
		handle: ins.slots[i]
		ctx:    ctx
		get:    get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_text, voidptr(b))
}

@[heap]
struct AttrBind {
	handle int
	name   string
	ctx    voidptr
	get    fn (ctx voidptr) string = unsafe { nil }
}

fn patch_attr(p voidptr) {
	b := unsafe { &AttrBind(p) }
	v := b.get(b.ctx)
	C.host_set_attr(b.handle, b.name.str, b.name.len, v.str, v.len)
}

pub fn bind_attr_ctx(mut ins Instance, i int, name string, ctx voidptr, get fn (ctx voidptr) string) {
	b := &AttrBind{
		handle: ins.slots[i]
		name:   name
		ctx:    ctx
		get:    get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_attr, voidptr(b))
}

@[heap]
struct ValueBind {
	handle int
	ctx    voidptr
	get    fn (ctx voidptr) string = unsafe { nil }
}

fn patch_value(p voidptr) {
	b := unsafe { &ValueBind(p) }
	v := b.get(b.ctx)
	C.host_set_value(b.handle, v.str, v.len)
}

pub fn bind_value_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) string, set fn (ctx voidptr, v string)) {
	handle := ins.slots[i]
	b := &ValueBind{
		handle: handle
		ctx:    ctx
		get:    get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_value, voidptr(b))
	vcsr_wasm_inputs << InputReg{
		set: set
		ctx: ctx
	}
	C.host_on_input(handle, vcsr_wasm_inputs.len - 1)
}

@[heap]
struct IfBind {
	handle int
	ctx    voidptr
	get    fn (ctx voidptr) bool = unsafe { nil }
}

fn patch_if(p voidptr) {
	b := unsafe { &IfBind(p) }
	C.host_set_visible(b.handle, if b.get(b.ctx) { 1 } else { 0 })
}

pub fn bind_if_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) bool) {
	b := &IfBind{
		handle: ins.slots[i]
		ctx:    ctx
		get:    get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_if, voidptr(b))
}

@[heap]
struct ListBind {
	handle int
	ctx    voidptr
	count  fn (ctx voidptr) int = unsafe { nil }
}

fn patch_list(p voidptr) {
	b := unsafe { &ListBind(p) }
	s := b.count(b.ctx).str()
	name := 'data-count'
	C.host_set_attr(b.handle, name.str, name.len, s.str, s.len)
}

pub fn bind_list_ctx(mut ins Instance, i int, ctx voidptr, count fn (ctx voidptr) int) {
	b := &ListBind{
		handle: ins.slots[i]
		ctx:    ctx
		count:  count
	}
	ins.effects << vcsr.effect_handle_ctx(patch_list, voidptr(b))
}

// --- event dispatch: host → wasm callbacks via integer indices --------------

// The host calls back into the module through three entry points. They are
// handed over as FUNCTION POINTERS (on wasm32: indices into the exported
// indirect function table), not looked up as named exports: V v3 drops — or
// emits only under a mangled C name — the `@[export]` fns of an imported module
// (the runtime is `vcsr.runtime` in any app outside the vcsr tree), and taking
// their address is also what keeps them alive through V's dead-code pass.
fn init_host() {
	if vcsr_host_ready {
		return
	}
	vcsr_host_ready = true
	C.host_init(voidptr(vcsr_dispatch), voidptr(vcsr_input_ptr), voidptr(vcsr_dispatch_input))
}

struct HandlerReg {
	run fn (ctx voidptr) = unsafe { nil }
	ctx voidptr
}

struct InputReg {
	set fn (ctx voidptr, v string) = unsafe { nil }
	ctx voidptr
}

__global (
	vcsr_host_ready    bool
	vcsr_wasm_handlers []HandlerReg
	vcsr_wasm_inputs   []InputReg
	vcsr_input_buf     []u8
)

// bind_event_ctx registers a closure-free handler and tells the host to call back
// vcsr_dispatch(idx) when the event fires on this node.
pub fn bind_event_ctx(mut ins Instance, i int, ctx voidptr, handler fn (ctx voidptr)) {
	name := ins.descs[i].name
	vcsr_wasm_handlers << HandlerReg{
		run: handler
		ctx: ctx
	}
	C.host_on(ins.slots[i], name.str, name.len, vcsr_wasm_handlers.len - 1)
}

// vcsr_dispatch is the host's entry point when a registered DOM event fires.
pub fn vcsr_dispatch(idx int) {
	if idx < 0 || idx >= vcsr_wasm_handlers.len {
		return
	}
	h := vcsr_wasm_handlers[idx]
	if h.run != unsafe { nil } {
		h.run(h.ctx)
	}
}

// vcsr_input_ptr returns a scratch buffer (≥ need bytes) the host writes a new
// two-way value into before calling vcsr_dispatch_input.
pub fn vcsr_input_ptr(need int) int {
	if vcsr_input_buf.len < need {
		vcsr_input_buf = []u8{len: need}
	}
	return int(u64(vcsr_input_buf.data))
}

// vcsr_dispatch_input is the host's entry point on a two-way input event: it reads
// the new value (written at ptr,len) and runs the registered writer.
pub fn vcsr_dispatch_input(idx int, ptr &u8, len int) {
	if idx < 0 || idx >= vcsr_wasm_inputs.len {
		return
	}
	r := vcsr_wasm_inputs[idx]
	s := unsafe { ptr.vstring_with_len(len) }
	if r.set != unsafe { nil } {
		r.set(r.ctx, s)
	}
}
