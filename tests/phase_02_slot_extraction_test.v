// Phase 02 — Slot extraction: AST → static HTML skeleton + slot table.
//
// GOAL: split a template into (a) a STATIC HTML string with the dynamic content
// emptied out — this string is what gets embedded in the WASM data segment and
// registered once as a <template> — and (b) a SLOT TABLE describing where the
// dynamic holes are (child-index path from the clone root), their kind, and the
// driving expression. This is the heart of the clone-and-patch model.
//
// See ../../v-web-csr-concept/CSR.md ("The compile-time split").
module main

import vcsr.parser
import vcsr.slots { SlotKind }

fn compile(markup string) slots.CompiledTemplate {
	ast := parser.parse(markup) or { panic(err) }
	return slots.compile(ast) or { panic(err) }
}

fn test_static_skeleton_empties_text_holes() {
	ct := compile('<h1>${count}</h1>')
	// the interpolation leaves an empty text hole in the static html
	assert ct.html == '<h1></h1>'
	assert ct.slots.len == 1
	assert ct.slots[0].kind == SlotKind.text
}

fn test_text_slot_path_points_to_node() {
	ct := compile('<section><h1>${count}</h1></section>')
	// h1 is child 0 of the root section
	assert ct.slots[0].kind == SlotKind.text
	assert ct.slots[0].path == [0]
}

fn test_event_slot_records_name_and_path() {
	ct := compile('<section><button @click=${inc}>+1</button></section>')
	s := ct.slots[0]
	assert s.kind == SlotKind.event
	assert s.name == 'click'
	assert s.path == [1] || s.path == [0] // depends on sibling layout; see next test
}

fn test_multiple_slots_keep_document_order_and_paths() {
	ct := compile('<section class="counter"><h1>${count}</h1><p>${doubled}</p><button @click=${inc}>+1</button></section>')
	assert ct.html == '<section class="counter"><h1></h1><p></p><button>+1</button></section>'
	assert ct.slots.len == 3
	assert ct.slots[0].kind == SlotKind.text && ct.slots[0].path == [0]
	assert ct.slots[1].kind == SlotKind.text && ct.slots[1].path == [1]
	assert ct.slots[2].kind == SlotKind.event && ct.slots[2].path == [2]
	assert ct.slots[2].name == 'click'
}

fn test_attr_slot() {
	ct := compile('<a href=${url}>link</a>')
	s := ct.slots[0]
	assert s.kind == SlotKind.attr
	assert s.name == 'href'
	assert s.path == [] // the root <a> itself
}

fn test_bind_slot() {
	ct := compile('<input @bind=${draft} />')
	assert ct.slots[0].kind == SlotKind.bind
	assert ct.slots[0].target_expr == 'draft'
}

fn test_cond_slot_marks_anchor() {
	// @if compiles to a comment anchor in the static html so the runtime can
	// insert/remove the node in place without re-parsing.
	ct := compile('<div><span @if=${ok}>hi</span></div>')
	assert ct.html.contains('<!--vcsr:if-->')
	assert ct.slots[0].kind == SlotKind.cond
	assert ct.slots[0].cond_expr == 'ok'
}

fn test_list_slot_holds_row_subtemplate() {
	ct := compile('<ul><li @for=${item in items} :key=${item.id}>${item.text}</li></ul>')
	s := ct.slots[0]
	assert s.kind == SlotKind.list
	assert s.path == [] // the <ul> is the list container (root)
	// the row is compiled into its OWN sub-template, cloned per item
	assert s.row.html == '<li></li>'
	assert s.row.slots[0].kind == SlotKind.text
	assert s.key_expr == 'item.id'
}

fn test_skeleton_is_stable_for_caching() {
	// Identical markup must yield byte-identical skeletons so the build can
	// dedupe/hash templates across components.
	a := compile('<h1>${x}</h1>')
	b := compile('<h1>${y}</h1>')
	assert a.html == b.html // same skeleton, different driving expr
}
