// Phase 02 — Slot extraction: AST → static HTML skeleton + slot table.
//
// Splits a template into (a) a STATIC HTML string with the dynamic content
// emptied out — embedded in the WASM and registered once as a <template> — and
// (b) a SLOT TABLE: an element-child-index `path` from the clone root, the slot
// `kind`, and the driving expression. The heart of the clone-and-patch model.
//
// IMPLEMENTED. Run: v test tests/phase_02_slot_extraction_test.v
// (with the repo on V's module path; see the repo README).
module main

import vcsr.parser
import vcsr.slots { SlotKind }

// `markup` is the contents of a component's `.html` file (vcsr's dialect).
fn compile(markup string) slots.CompiledTemplate {
	tree := parser.parse_template(markup) or { panic(err) }
	return slots.compile(tree) or { panic(err) }
}

// --- text slots -------------------------------------------------------------

fn test_static_skeleton_empties_text_holes() {
	ct := compile('<h1>{{ count }}</h1>')
	assert ct.html == '<h1></h1>'
	assert ct.slots.len == 1
	assert ct.slots[0].kind == SlotKind.text
}

fn test_text_slot_path_points_to_node() {
	ct := compile('<section><h1>{{ count }}</h1></section>')
	assert ct.slots[0].kind == SlotKind.text
	assert ct.slots[0].path == [0] // h1 is element-child 0 of the root <section>
}

fn test_text_slot_deep_path() {
	ct := compile('<div><section><p>{{ x }}</p></section></div>')
	assert ct.html == '<div><section><p></p></section></div>'
	assert ct.slots[0].kind == SlotKind.text
	assert ct.slots[0].path == [0, 0] // div > section(0) > p(0)
}

// --- event / attr / bind slots ---------------------------------------------

fn test_event_slot_records_name_and_path() {
	ct := compile('<section><button @click="inc">+1</button></section>')
	s := ct.slots[0]
	assert s.kind == SlotKind.event
	assert s.name == 'click'
	assert s.path == [0] // the button is element-child 0
}

fn test_multiple_events_same_node() {
	ct := compile('<button @click="a" @mouseenter="b"></button>')
	assert ct.slots.len == 2
	assert ct.slots[0].kind == SlotKind.event && ct.slots[0].name == 'click'
	assert ct.slots[1].kind == SlotKind.event && ct.slots[1].name == 'mouseenter'
	assert ct.slots[0].path == []int{} && ct.slots[1].path == []int{}
}

fn test_attr_slot() {
	ct := compile('<a :href="url">link</a>')
	s := ct.slots[0]
	assert s.kind == SlotKind.attr
	assert s.name == 'href'
	assert s.path == []int{} // the root <a> itself
	assert ct.html == '<a>link</a>' // the bound attr is stripped from the skeleton
}

fn test_bind_slot() {
	ct := compile('<input @bind="draft" />')
	assert ct.slots[0].kind == SlotKind.bind
	assert ct.slots[0].target_expr == 'draft'
}

fn test_static_attrs_are_preserved_dynamic_stripped() {
	ct := compile('<a href="/x" @click="go">y</a>')
	assert ct.html == '<a href="/x">y</a>'
	assert ct.slots.len == 1 && ct.slots[0].kind == SlotKind.event
}

// --- multiple slots, document order ----------------------------------------

fn test_multiple_slots_keep_document_order_and_paths() {
	ct :=
		compile('<section class="counter"><h1>{{ count }}</h1><p>{{ doubled }}</p><button @click="inc">+1</button></section>')
	assert ct.html == '<section class="counter"><h1></h1><p></p><button>+1</button></section>'
	assert ct.slots.len == 3
	assert ct.slots[0].kind == SlotKind.text && ct.slots[0].path == [0]
	assert ct.slots[1].kind == SlotKind.text && ct.slots[1].path == [1]
	assert ct.slots[2].kind == SlotKind.event && ct.slots[2].path == [2]
	assert ct.slots[2].name == 'click'
}

// --- conditional ------------------------------------------------------------

fn test_cond_slot_marks_anchor() {
	ct := compile('<div><span @if="ok">hi</span></div>')
	assert ct.html == '<div><!----></div>'
	assert ct.slots[0].path == []int{}
	assert ct.slots[0].anchor == 0
	assert ct.slots[0].kind == SlotKind.cond
	assert ct.slots[0].cond_expr == 'ok'
	// the conditional content is kept as a sub-template
	assert ct.slots[0].row.html == '<span>hi</span>'
}

// --- keyed list -------------------------------------------------------------

fn test_list_slot_holds_row_subtemplate() {
	ct := compile('<ul><li @for="item in items" :key="item.id">{{ item.text }}</li></ul>')
	s := ct.slots[0]
	assert s.kind == SlotKind.list
	assert s.path == []int{} // the <ul> is the list container (root)
	assert s.key_expr == 'item.id'
	// the row is compiled into its OWN sub-template, cloned per item
	assert s.row.html == '<li></li>'
	assert s.row.slots.len == 1
	assert s.row.slots[0].kind == SlotKind.text
}

fn test_list_row_keeps_inner_event() {
	ct :=
		compile('<ul><li @for="t in todos" :key="t.id"><button @click="remove(t.id)">x</button></li></ul>')
	row := ct.slots[0].row
	assert row.html == '<li><button>x</button></li>'
	assert row.slots[0].kind == SlotKind.event
	assert row.slots[0].path == [0] // button is element-child 0 of the row <li>
}

// --- misc -------------------------------------------------------------------

fn test_skeleton_is_stable_for_caching() {
	// Identical markup must yield byte-identical skeletons so the build can
	// dedupe/hash templates across components.
	a := compile('<h1>{{ x }}</h1>')
	b := compile('<h1>{{ y }}</h1>')
	assert a.html == b.html // same skeleton, different driving expr
}

fn test_fully_static_template_has_no_slots() {
	ct := compile('<footer>© vcsr</footer>')
	assert ct.slots.len == 0
	assert ct.html == '<footer>© vcsr</footer>'
}

fn test_text_mixed_with_interpolations_is_one_text_slot() {
	ct := compile('<p>Hello {{ name }}, you have {{ n }} items!</p>')
	assert ct.html == '<p></p>'
	assert ct.slots.len == 1
	s := ct.slots[0]
	assert s.kind == SlotKind.text && s.path == []int{} && s.anchor == -1
	assert s.parts.map(it.text) == ['Hello ', 'name', ', you have ', 'n', ' items!']
	assert s.parts.map(it.is_expr) == [false, true, false, true, false]
	assert s.text_exprs() == ['name', 'n']
}

fn test_interpolation_beside_elements_gets_an_anchored_text_node() {
	ct := compile('<p>{{ a }} and <b>bold</b> then {{ b }}</p>')
	assert ct.html == '<p><!----> and <b>bold</b> then <!----></p>'
	assert ct.slots.len == 2
	assert ct.slots[0].anchor == 0 && ct.slots[0].expr == 'a'
	assert ct.slots[1].anchor == 1 && ct.slots[1].expr == 'b'
}

fn test_anchor_indices_count_every_anchor_in_the_container() {
	ct := compile('<ul>{{ title }}<li @for="x in xs">{{ x }}</li><p @if="on">y</p></ul>')
	assert ct.html == '<ul><!----><!----><!----></ul>'
	assert ct.slots.map(it.anchor) == [0, 1, 2]
	assert ct.slots.map(it.kind) == [SlotKind.text, .list, .cond]
}

fn test_pretty_printed_template_condenses_to_a_compact_skeleton() {
	ct := compile('<main class="counter">\n  <h1>\n    {{ count }}\n  </h1>\n  <p class="muted">double <span>{{ doubled }}</span></p>\n  <button @click="inc">+1</button>\n</main>')
	assert ct.html == '<main class="counter"><h1></h1><p class="muted">double <span></span></p><button>+1</button></main>'
	assert ct.slots.map(it.path) == [[0], [1, 0], [2]]
}

fn test_inline_spaces_between_elements_survive() {
	assert compile('<p><b>a</b> <i>b</i></p>').html == '<p><b>a</b> <i>b</i></p>'
}

fn test_user_comments_never_reach_the_skeleton() {
	assert compile('<div><!-- note --><p>x</p></div>').html == '<div><p>x</p></div>'
}

fn test_attribute_values_are_quoted_safely() {
	assert compile('<a title=\'say "hi"\'>x</a>').html == '<a title="say &quot;hi&quot;">x</a>'
}

fn test_void_and_self_closed_elements_serialize_correctly() {
	// void: no closing tag; self-closed non-void: closed, so later paths don't shift
	ct := compile('<div><input @bind="name"><span/><b>{{ x }}</b></div>')
	assert ct.html == '<div><input><span></span><b></b></div>'
	assert ct.slots[0].kind == SlotKind.bind && ct.slots[0].path == [0]
	assert ct.slots[1].kind == SlotKind.text && ct.slots[1].path == [2]
}

fn test_whitespace_is_kept_inside_pre() {
	assert compile('<div><pre>  a\n   b  </pre></div>').html == '<div><pre>  a\n   b  </pre></div>'
}

fn test_entities_in_text_slot_parts_are_decoded() {
	// textContent doesn't decode entities, so literal parts arrive decoded
	ct := compile('<p>&copy; {{ year }} &mdash; a &amp; b &lt; c &#x2713; &#65; &bogus; &</p>')
	assert ct.slots[0].parts.map(it.text) == ['© ', 'year', ' — a & b < c ✓ A &bogus; &']
	assert slots.decode_entities('no entities') == 'no entities'
}
