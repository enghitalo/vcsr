// The NATIVE rendering backend (default; compiled when -d wasm_browser is NOT set).
//
// An in-memory mock DOM (`Node` tree) built by reusing vcsr's own template parser,
// so the whole engine is testable without a browser. `instance()` clones the
// skeleton; bind_*(_ctx) wire each slot to a reactive effect; html() serializes.
// The wasm backend (backend_wasm_d_wasm_browser.v) presents the SAME public API
// (Template.instance / bind_*_ctx / Instance.view / View) but drives the real DOM
// through host FFI and holds no maps (string-keyed maps don't run on wasm — see
// docs/WASM-PATHS-ANALYSIS.md §2.1). Build native tests with -enable-globals.
module runtime

import strings
import vcsr
import vcsr.ast
import vcsr.parser

// Node is a DOM node — the NATIVE mock backend (an in-memory tree). A node is
// either a text node (`is_text`, content in `text`) or an element. `children` is
// the ORDERED child list — text and element nodes interleaved as in the source —
// so serialization preserves order; `path` indexing counts only element children
// (see element_child), matching the element-child-index paths phase 02 emits.
@[heap]
struct Node {
mut:
	is_text  bool // text node: `text` is the content; tag/attrs/children unused
	tag      string
	text     string // text-node content
	attrs    map[string]string
	value    string // form value (two-way bind)
	visible  bool = true // @if toggle
	children []&Node          // ordered: text nodes + element nodes
	on       map[string]fn () // event name → handler (closure form, native)
	on_input fn (v string) = unsafe { nil } // two-way input writer (closure form, native)
	// closure-FREE handler slots (what codegen emits; wasm-safe — see signal.v):
	on_ctx       map[string]EvtHandler // event name → (top-level fn + ctx)
	on_input_ctx &InputHandler = unsafe { nil } // two-way writer (top-level fn + ctx)
}

// EvtHandler / InputHandler are closure-free event handlers: a top-level fn plus
// its context pointer (no captures, so they run on wasm). The `*_ctx` bindings
// store these; dispatch()/input() invoke them.
struct EvtHandler {
	run fn (ctx voidptr) = unsafe { nil }
	ctx voidptr
}

@[heap]
struct InputHandler {
	set fn (ctx voidptr, v string) = unsafe { nil }
	ctx voidptr
}

// set_text sets an element's textContent — replacing its children with one text
// node, like the DOM setter.
fn (mut n Node) set_text(s string) {
	n.children = [
		&Node{
			is_text: true
			text:    s
		},
	]
}

// Instance is one clone of a template: the live tree, its resolved slot nodes
// (so bind_* can address a slot by index without re-walking), and the effects
// its bindings created (so it can detach them all on unmount — see dispose).
pub struct Instance {
mut:
	root    &Node
	slots   []&Node
	descs   []SlotDesc
	effects []&vcsr.Effect
}

// View is the live root handed back by view(), carrying the effects its slot
// bindings created so an owner (the App) can dispose them on unmount/re-render.
// `.html()` serializes it (tests/SSR).
pub struct View {
pub:
	root &Node
mut:
	effects []&vcsr.Effect
}

// dispose detaches every effect this view's slot bindings created — the View-level
// teardown the App calls when it drops or replaces a view.
pub fn (mut v View) dispose() {
	for mut e in v.effects {
		e.dispose()
	}
	v.effects = []
}

// instance clones the skeleton and resolves every slot node. The receiver is by
// value because codegen calls it on a `const` Template.
pub fn (t Template) instance() Instance {
	root := build_tree(t.html)
	mut slots := []&Node{cap: t.slots.len}
	for d in t.slots {
		slots << node_at(root, d.path)
	}
	return Instance{
		root:  root
		slots: slots
		descs: t.slots.clone()
	}
}

// view hands back the live root plus the effects to dispose on teardown.
pub fn (mut ins Instance) view() View {
	return View{
		root:    ins.root
		effects: ins.effects
	}
}

// --- the bindings: wire one slot to the reactive layer ----------------------

// bind_text makes a slot element's textContent follow `get`.
pub fn bind_text(mut ins Instance, i int, get fn () string) {
	mut node := ins.slots[i]
	ins.effects << vcsr.effect_handle(fn [mut node, get] () {
		node.set_text(get())
	})
}

// bind_attr makes attribute `name` on a slot element follow `get`.
pub fn bind_attr(mut ins Instance, i int, name string, get fn () string) {
	mut node := ins.slots[i]
	ins.effects << vcsr.effect_handle(fn [mut node, name, get] () {
		node.attrs[name] = get()
	})
}

// bind_event registers a DOM handler (the event name is the slot's `name`).
pub fn bind_event(mut ins Instance, i int, handler fn ()) {
	name := ins.descs[i].name
	mut node := ins.slots[i]
	node.on[name] = handler
}

// bind_value is two-way: the slot's value follows `get`, and an input event
// writes the new value back through `set`.
pub fn bind_value(mut ins Instance, i int, get fn () string, set fn (v string)) {
	mut node := ins.slots[i]
	ins.effects << vcsr.effect_handle(fn [mut node, get] () {
		node.value = get()
	})
	node.on_input = set
}

// bind_if makes a slot element present only while `get` is true.
pub fn bind_if(mut ins Instance, i int, get fn () bool) {
	mut node := ins.slots[i]
	ins.effects << vcsr.effect_handle(fn [mut node, get] () {
		node.visible = get()
	})
}

// bind_list tracks a keyed list's length reactively.
//
// NOTE: the codegen contract currently supplies only the row COUNT (`fn () int`).
// Per-row cloning + keyed (`:key`) reconciliation — the real payoff — needs the
// row sub-template and a render closure, which is the next codegen↔runtime
// co-design step (DESIGN.md). Until then this keeps the length dependency live
// (exposed as `data-count`) so the wiring is correct and observable.
pub fn bind_list(mut ins Instance, i int, count fn () int) {
	mut node := ins.slots[i]
	ins.effects << vcsr.effect_handle(fn [mut node, count] () {
		node.attrs['data-count'] = count().str()
	})
}

// --- closure-FREE bindings (what codegen emits; wasm-safe — see signal.v) ----
//
// Each mirrors its bind_* twin but takes a component CONTEXT pointer + a TOP-LEVEL
// fn instead of a capturing closure, so the effect it creates runs on wasm. The
// binding context (node + ctx + the getter) is heap-allocated and handed to
// effect_handle_ctx; a top-level patch_* fn reads it on each run. (Native uses a
// conservative GC that scans the voidptr, so the context stays alive; wasm builds
// `-gc none`, so nothing is collected. Either way the context outlives the effect.)

@[heap]
struct TextBind {
	node &Node
	ctx  voidptr
	get  fn (ctx voidptr) string = unsafe { nil }
}

fn patch_text(p voidptr) {
	b := unsafe { &TextBind(p) }
	mut n := b.node
	n.set_text(b.get(b.ctx))
}

// bind_text_ctx makes slot `i`'s textContent follow `get(ctx)`.
pub fn bind_text_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) string) {
	b := &TextBind{
		node: ins.slots[i]
		ctx:  ctx
		get:  get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_text, voidptr(b))
}

@[heap]
struct AttrBind {
	node &Node
	name string
	ctx  voidptr
	get  fn (ctx voidptr) string = unsafe { nil }
}

fn patch_attr(p voidptr) {
	b := unsafe { &AttrBind(p) }
	mut n := b.node
	n.attrs[b.name] = b.get(b.ctx)
}

// bind_attr_ctx makes attribute `name` on slot `i` follow `get(ctx)`.
pub fn bind_attr_ctx(mut ins Instance, i int, name string, ctx voidptr, get fn (ctx voidptr) string) {
	b := &AttrBind{
		node: ins.slots[i]
		name: name
		ctx:  ctx
		get:  get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_attr, voidptr(b))
}

// bind_event_ctx registers a closure-free DOM handler on slot `i` (event = the
// slot's `name`); dispatch() invokes `handler(ctx)`.
pub fn bind_event_ctx(mut ins Instance, i int, ctx voidptr, handler fn (ctx voidptr)) {
	name := ins.descs[i].name
	mut node := ins.slots[i]
	node.on_ctx[name] = EvtHandler{
		run: handler
		ctx: ctx
	}
}

@[heap]
struct ValueBind {
	node &Node
	ctx  voidptr
	get  fn (ctx voidptr) string = unsafe { nil }
}

fn patch_value(p voidptr) {
	b := unsafe { &ValueBind(p) }
	mut n := b.node
	n.value = b.get(b.ctx)
}

// bind_value_ctx is two-way: the slot's value follows `get(ctx)`, and an input
// event runs `set(ctx, v)`.
pub fn bind_value_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) string, set fn (ctx voidptr, v string)) {
	mut node := ins.slots[i]
	b := &ValueBind{
		node: node
		ctx:  ctx
		get:  get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_value, voidptr(b))
	node.on_input_ctx = &InputHandler{
		set: set
		ctx: ctx
	}
}

@[heap]
struct IfBind {
	node &Node
	ctx  voidptr
	get  fn (ctx voidptr) bool = unsafe { nil }
}

fn patch_if(p voidptr) {
	b := unsafe { &IfBind(p) }
	mut n := b.node
	n.visible = b.get(b.ctx)
}

// bind_if_ctx makes slot `i` present only while `get(ctx)` is true.
pub fn bind_if_ctx(mut ins Instance, i int, ctx voidptr, get fn (ctx voidptr) bool) {
	b := &IfBind{
		node: ins.slots[i]
		ctx:  ctx
		get:  get
	}
	ins.effects << vcsr.effect_handle_ctx(patch_if, voidptr(b))
}

@[heap]
struct ListBind {
	node  &Node
	ctx   voidptr
	count fn (ctx voidptr) int = unsafe { nil }
}

fn patch_list(p voidptr) {
	b := unsafe { &ListBind(p) }
	mut n := b.node
	n.attrs['data-count'] = b.count(b.ctx).str()
}

// bind_list_ctx tracks a keyed list's length reactively (count(ctx)).
pub fn bind_list_ctx(mut ins Instance, i int, ctx voidptr, count fn (ctx voidptr) int) {
	b := &ListBind{
		node:  ins.slots[i]
		ctx:   ctx
		count: count
	}
	ins.effects << vcsr.effect_handle_ctx(patch_list, voidptr(b))
}

// dispose detaches every effect this instance's bindings created, so dropping a
// component (route change, list-row removal) does not leak its slot effects onto
// longer-lived signals. Codegen calls this on unmount.
pub fn (mut ins Instance) dispose() {
	for mut e in ins.effects {
		e.dispose()
	}
	ins.effects = []
}

// --- host-event entry points (also used by tests) ---------------------------

// dispatch fires a registered handler on slot `i` — what the host's event
// bridge does when a real DOM event arrives.
pub fn (mut ins Instance) dispatch(i int, event string) {
	mut node := ins.slots[i]
	if h := node.on[event] {
		h() // closure handler (native)
	}
	if h := node.on_ctx[event] {
		h.run(h.ctx) // closure-free handler (codegen/wasm)
	}
}

// input simulates a user typing into a two-way-bound slot: set the value, then
// run the registered writer (as a real `input` event would).
pub fn (mut ins Instance) input(i int, v string) {
	mut node := ins.slots[i]
	node.value = v
	if node.on_input != unsafe { nil } {
		node.on_input(v) // closure writer (native)
	}
	if node.on_input_ctx != unsafe { nil } {
		node.on_input_ctx.set(node.on_input_ctx.ctx, v) // closure-free writer (codegen/wasm)
	}
}

// value_of reads a slot element's current value — what the host reads off the
// DOM node (form value isn't serialized into html()).
pub fn (ins Instance) value_of(i int) string {
	return ins.slots[i].value
}

// --- the native mock DOM ----------------------------------------------------

// build_tree parses the static skeleton into an element tree, reusing vcsr's own
// template parser so the element-child indexing matches the emitted paths.
fn build_tree(html string) &Node {
	tree := parser.parse_template(html) or { return &Node{
		tag: 'div'
	} }
	return convert(tree.root)
}

// convert turns an AST element into a mock Node, preserving child ORDER: static
// attrs carried over; text children become text nodes in place; element and
// component children are recursed. (Interpolation children don't appear — the
// skeleton's holes are emptied.) Text nodes stay in `children` so they keep
// their position relative to elements.
fn convert(n ast.Node) &Node {
	mut node := &Node{
		tag: n.tag
	}
	for a in n.attrs {
		node.attrs[a.name] = a.value
	}
	for ch in n.children {
		match ch.kind {
			.text {
				node.children << &Node{
					is_text: true
					text:    ch.text
				}
			}
			.element, .component {
				node.children << convert(ch)
			}
			.interpolation {} // skeleton holes are emptied; none here
		}
	}
	return node
}

// node_at walks `path` down element children (text nodes don't count, matching
// the element-child-index path scheme) from the clone root.
fn node_at(root &Node, path []int) &Node {
	mut cur := root
	for idx in path {
		cur = element_child(cur, idx)
	}
	return cur
}

// element_child returns the `idx`-th ELEMENT child of `n`, skipping text nodes.
// A bad index degrades to `n` itself rather than panicking.
fn element_child(n &Node, idx int) &Node {
	mut ei := 0
	for ch in n.children {
		if ch.is_text {
			continue
		}
		if ei == idx {
			return ch
		}
		ei++
	}
	return n
}

// void_tags get no closing tag (HTML void elements).
const void_tags = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
	'param', 'source', 'track', 'wbr']

// html serializes the live tree (an @if-hidden element renders as nothing).
pub fn (v View) html() string {
	mut sb := strings.new_builder(128)
	write_html(mut sb, v.root)
	return sb.str()
}

fn write_html(mut sb strings.Builder, n &Node) {
	if n.is_text {
		sb.write_string(n.text)
		return
	}
	if !n.visible {
		return
	}
	sb.write_string('<${n.tag}')
	for k, val in n.attrs {
		sb.write_string(' ${k}="${val}"')
	}
	sb.write_string('>')
	if n.tag in void_tags {
		return
	}
	for ch in n.children {
		write_html(mut sb, ch)
	}
	sb.write_string('</${n.tag}>')
}
