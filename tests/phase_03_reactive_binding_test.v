// Phase 03 — Reactive binding: slot table → a binding plan.
//
// For each slot, decide how it wires to the reactive runtime so a signal write
// updates ONLY the slot nodes that read it (no virtual DOM, no diff): text/attr
// → effect, event → listener, @bind → two-way, @if → cond, @for → keyed list.
// For each reactive expression the dependency set (`reads`) is extracted.
//
// `reads` is the candidate free-identifier set; whether a name is a signal /
// computed / loop var is resolved in phase 04 against the struct.
//
// IMPLEMENTED. Run: v test tests/phase_03_reactive_binding_test.v
module main

import vcsr.parser
import vcsr.slots
import vcsr.bind { BindKind, DomTarget }

fn plan(markup string) bind.BindingPlan {
	tree := parser.parse_template(markup) or { panic(err) }
	ct := slots.compile(tree) or { panic(err) }
	return bind.plan(ct) or { panic(err) }
}

// --- text / effect ----------------------------------------------------------

fn test_text_slot_becomes_effect() {
	p := plan('<h1>{{ count }}</h1>')
	b := p.bindings[0]
	assert b.kind == BindKind.effect
	assert b.slot == 0
	assert b.reads == ['count']
	assert b.writes_dom == DomTarget.text_content
}

fn test_effect_dependency_set_is_exact() {
	p := plan('<p>{{ a + b * 2 }}</p>')
	assert p.bindings[0].reads.sorted() == ['a', 'b'] // 2 is a literal, not a dep
}

fn test_dependency_drops_member_tails() {
	p := plan('<p>{{ user.name }}</p>')
	assert p.bindings[0].reads == ['user'] // `.name` is a property, not a dep
}

fn test_dependency_dedupes() {
	p := plan('<p>{{ a + a + b }}</p>')
	assert p.bindings[0].reads == ['a', 'b']
}

fn test_single_identifier_read() {
	// `doubled` (a computed) is just a single free identifier at this phase;
	// the signal-vs-computed distinction is resolved later, in phase 04.
	p := plan('<p>{{ doubled }}</p>')
	assert p.bindings[0].kind == BindKind.effect
	assert p.bindings[0].reads == ['doubled']
}

// --- event / listener -------------------------------------------------------

fn test_event_slot_becomes_listener() {
	p := plan('<button @click="inc">+1</button>')
	b := p.bindings[0]
	assert b.kind == BindKind.listener
	assert b.event == 'click'
	assert b.handler == 'inc'
	assert !b.prevent_default
}

fn test_event_modifier_prevent_default() {
	p := plan('<form @submit.prevent="save"></form>')
	b := p.bindings[0]
	assert b.kind == BindKind.listener
	assert b.event == 'submit'
	assert b.prevent_default
}

fn test_event_handler_expression() {
	p := plan('<button @click="remove(item.id)">x</button>')
	assert p.bindings[0].handler == 'remove(item.id)'
}

// --- two-way bind -----------------------------------------------------------

fn test_two_way_bind_reads_and_writes() {
	p := plan('<input @bind="draft" />')
	b := p.bindings[0]
	assert b.kind == BindKind.two_way
	assert b.reads == ['draft']
	assert b.dom_event == 'input'
	assert b.writes_dom == DomTarget.value
}

// --- attribute --------------------------------------------------------------

fn test_attr_slot_becomes_effect() {
	p := plan('<a :href="url">x</a>')
	b := p.bindings[0]
	assert b.kind == BindKind.effect
	assert b.writes_dom == DomTarget.attribute
	assert b.reads == ['url']
}

// --- conditional ------------------------------------------------------------

fn test_cond_binding_toggles_node() {
	p := plan('<div><span @if="ok">hi</span></div>')
	b := p.bindings[0]
	assert b.kind == BindKind.cond
	assert b.reads == ['ok']
}

fn test_cond_drops_none_literal() {
	p := plan('<div><span @if="report != none">x</span></div>')
	assert p.bindings[0].reads == ['report'] // `none` is excluded
}

// --- keyed list -------------------------------------------------------------

fn test_list_binding_is_keyed() {
	p := plan('<ul><li @for="item in items" :key="item.id">{{ item.text }}</li></ul>')
	b := p.bindings[0]
	assert b.kind == BindKind.keyed_list
	assert b.reads == ['items'] // the source; not the `item` loop variable
	assert b.key == 'item.id'
	// the row sub-template has its own plan
	assert b.row_plan.bindings.len == 1
	assert b.row_plan.bindings[0].kind == BindKind.effect
}

// --- ordering & static ------------------------------------------------------

fn test_binding_slots_match_document_order() {
	p :=
		plan('<section><h1>{{ count }}</h1><p>{{ doubled }}</p><button @click="inc">+1</button></section>')
	assert p.bindings.len == 3
	assert p.bindings[0].kind == BindKind.effect && p.bindings[0].slot == 0
	assert p.bindings[1].kind == BindKind.effect && p.bindings[1].slot == 1
	assert p.bindings[2].kind == BindKind.listener && p.bindings[2].slot == 2
}

fn test_no_binding_for_fully_static_template() {
	p := plan('<footer>© vcsr</footer>')
	assert p.bindings.len == 0 // nothing reactive → zero runtime overhead
}

fn test_plan_uses_helper() {
	p := plan('<h1>{{ count }}</h1>')
	assert p.uses('count')
	assert !p.uses('nope')
}
