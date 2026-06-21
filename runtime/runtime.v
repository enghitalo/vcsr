// The Template / bind engine — the runtime the generated `view()` imports.
//
// A component compiles (phase 04) to a STATIC SKELETON plus a SLOT TABLE: the
// markup with its dynamic holes emptied, and, for each hole, where it lives
// (an element-child-index `path` from the clone root) and what it is (text /
// attribute / event / two-way / @if / @for). At runtime `view()` does:
//
//   1. instance()      — clone the skeleton into a fresh node tree;
//   2. bind_*(...)      — wire each slot to a reactive effect (vcsr.signal):
//                         reading a signal subscribes the slot, writing it
//                         re-runs ONLY that slot's patch — O(dependents), no
//                         diff, no virtual DOM;
//   3. view()           — hand back the live root.
//
// This is the NATIVE backend: the node tree is an in-memory element model built
// by reusing vcsr's own template parser, so the whole engine is testable without
// a browser. On the wasm/browser target the same bind_* wiring drives a cloned
// <template> through the `js` FFI (docs/WASM-ABI.md) — clone, walk childNodes to
// `path`, set textContent / addEventListener — but the reactive layer is byte
// for byte identical. Build with -enable-globals (the effect stack is global).
module runtime

import strings
import vcsr
import vcsr.ast
import vcsr.parser

// SlotKind classifies a dynamic hole. Matches phase 02 / phase 04 exactly.
pub enum SlotKind {
	text  // an element's textContent follows an expression
	attr  // an attribute value follows an expression (`name`)
	event // a DOM event runs a handler (`name` = event, e.g. 'click')
	bind  // two-way: value follows an expression AND writes back on input
	cond  // @if: the element is present only while the expression is true
	list  // @for: a keyed list of rows
}

// SlotDesc locates one hole and says what it is. Emitted as a plain const by
// codegen, so every field is pub and the shape is frozen.
pub struct SlotDesc {
pub:
	kind SlotKind
	path []int  // element-child-index path from the clone root
	name string // attribute name (attr) or event name (event); else ''
}

// Template is a component's compiled form: the static skeleton + the slot table.
pub struct Template {
pub:
	html  string
	slots []SlotDesc
}

// Node is a DOM node — the NATIVE mock backend (an in-memory tree). On wasm
// these are cloned-<template> node handles and the ops below are imported DOM
// calls; the bind_* wiring that drives them is the same. A node is either a
// text node (`is_text`, content in `text`) or an element. `children` is the
// ORDERED child list — text and element nodes interleaved as in the source —
// so serialization preserves order; `path` indexing counts only element
// children (see element_child), matching the element-child-index paths phase
// 02 emits. Setting an element's text (a text slot) replaces its children with
// a single text node, exactly like the DOM `textContent` setter.
@[heap]
struct Node {
mut:
	is_text  bool // text node: `text` is the content; tag/attrs/children unused
	tag      string
	text     string // text-node content
	attrs    map[string]string
	value    string // form value (two-way bind)
	visible  bool = true // @if toggle
	children []&Node // ordered: text nodes + element nodes
	on       map[string]fn () // event name → handler
	on_input fn (v string) = unsafe { nil } // two-way input writer
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
		h()
	}
}

// input simulates a user typing into a two-way-bound slot: set the value, then
// run the registered writer (as a real `input` event would).
pub fn (mut ins Instance) input(i int, v string) {
	mut node := ins.slots[i]
	node.value = v
	if node.on_input != unsafe { nil } {
		node.on_input(v)
	}
}

// value_of reads a slot element's current value — what the host reads off the
// DOM node (form value isn't serialized into html()).
pub fn (ins Instance) value_of(i int) string {
	return ins.slots[i].value
}

// --- value → string (the wrapper codegen puts around every dynamic expr) -----

// to_str renders any bound value to text. Codegen wraps every text/attr/value
// expression in this, so it is a no-op on strings and correct for the scalar
// types bindings use (int/f64/bool). NOTE: a non-scalar operand (a struct/map)
// renders via V's autogenerated debug str() — a multi-line dump in the DOM. The
// intent is that bound expressions are string/numeric; richer types should be
// formatted in the component before binding (a future codegen type-check could
// enforce this).
pub fn to_str[T](v T) string {
	return '${v}'
}

// --- the native mock DOM ----------------------------------------------------

// build_tree parses the static skeleton into an element tree, reusing vcsr's own
// template parser so the element-child indexing matches the emitted paths.
fn build_tree(html string) &Node {
	tree := parser.parse_template(html) or {
		return &Node{
			tag: 'div'
		}
	}
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
		return // void element: no children, no closing tag
	}
	for ch in n.children {
		write_html(mut sb, ch)
	}
	sb.write_string('</${n.tag}>')
}
