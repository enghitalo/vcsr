// Phase 03 — Reactive binding codegen: slots → fine-grained signal wiring.
//
// GOAL: for each slot, emit code that binds it to the reactive runtime so that
// a write to a signal updates ONLY the slot nodes that read it (no virtual DOM,
// no diff). Text/attr slots become `effect`s; event slots become listeners;
// bind slots become two-way wiring; the codegen tracks exactly which signals an
// expression reads.
//
// These tests assert over the generated binding plan (an IR), not raw strings,
// so they're robust to formatting.
module main

import vcsr.parser
import vcsr.slots
import vcsr.bind { BindKind }

fn plan(markup string) bind.BindingPlan {
	ast := parser.parse(markup) or { panic(err) }
	ct := slots.compile(ast) or { panic(err) }
	return bind.plan(ct) or { panic(err) }
}

fn test_text_slot_becomes_effect() {
	p := plan('<h1>${count}</h1>')
	b := p.bindings[0]
	assert b.kind == BindKind.effect
	assert b.slot == 0
	assert b.reads == ['count'] // dependency set drives re-run
	assert b.writes_dom == .text_content
}

fn test_effect_dependency_set_is_exact() {
	// only signals actually read are dependencies; `k` is a constant, not a dep
	p := plan('<p>${a + b * 2}</p>')
	assert p.bindings[0].reads.sorted() == ['a', 'b']
}

fn test_computed_is_memoized_node() {
	p := plan('<p>${doubled}</p>')
	// `doubled` resolves to a computed; the plan references it without inlining
	assert p.bindings[0].reads == ['doubled']
	assert p.uses_computed('doubled')
}

fn test_event_slot_becomes_listener() {
	p := plan('<button @click=${inc}>+1</button>')
	b := p.bindings[0]
	assert b.kind == BindKind.listener
	assert b.event == 'click'
	assert b.handler == 'inc'
}

fn test_event_modifier_prevent_default() {
	p := plan('<form @submit.prevent=${save}></form>')
	b := p.bindings[0]
	assert b.event == 'submit'
	assert b.prevent_default
}

fn test_two_way_bind_reads_and_writes() {
	p := plan('<input @bind=${draft} />')
	b := p.bindings[0]
	assert b.kind == BindKind.two_way
	// input event writes the signal; signal change writes the .value
	assert b.reads == ['draft']
	assert b.dom_event == 'input'
	assert b.writes_dom == .value
}

fn test_cond_binding_toggles_node() {
	p := plan('<div><span @if=${ok}>hi</span></div>')
	b := p.bindings[0]
	assert b.kind == BindKind.cond
	assert b.reads == ['ok']
}

fn test_list_binding_is_keyed() {
	p := plan('<ul><li @for=${item in items} :key=${item.id}>${item.text}</li></ul>')
	b := p.bindings[0]
	assert b.kind == BindKind.keyed_list
	assert b.reads == ['items']
	assert b.key == 'item.id'
	// each row gets its own nested binding plan, evaluated per item
	assert b.row_plan.bindings[0].kind == BindKind.effect
}

fn test_no_binding_for_fully_static_template() {
	p := plan('<footer>© vcsr</footer>')
	assert p.bindings.len == 0 // nothing reactive → zero runtime overhead
}
