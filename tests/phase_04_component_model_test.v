// Phase 04 — Component model: typed props, composition, hoisting decision.
//
// GOAL: analyze a `@[component]` struct + its `view()`/`style()` into a
// Component descriptor: typed props, the compiled template, child components it
// composes, lifecycle hooks, and whether it should be hoisted into the shared
// core (used by ≥2 routes) or kept route-local. Prop type errors must be caught
// at compile time.
module main

import vcsr.component { analyze, HoistDecision }

const button_src = "
@[component]
pub struct Button {
pub:
	label    string
	on_click fn ()
}
pub fn (b Button) view() vcsr.View {
	return \$vui('<button class=\"btn\">\${b.label}</button>')
}
"

fn test_extracts_typed_props() {
	c := analyze(button_src)!
	assert c.name == 'Button'
	assert c.prop('label')!.typ == 'string'
	assert c.prop('on_click')!.typ == 'fn ()'
}

fn test_compiles_components_template() {
	c := analyze(button_src)!
	assert c.template.html == '<button class="btn"></button>'
	assert c.template.slots.len == 1 // the label text slot
}

fn test_detects_lifecycle_hooks() {
	src := button_src + '\npub fn (mut b Button) on_mount() {}'
	c := analyze(src)!
	assert c.has_hook('on_mount')
}

fn test_detects_child_composition() {
	page := "
	@[component]
	pub struct Page {}
	pub fn (p Page) view() vcsr.View {
		return \$vui('<main><Button label=\${\"ok\"} on_click=\${noop} /></main>')
	}"
	c := analyze(page)!
	assert 'Button' in c.children
}

fn test_prop_type_mismatch_is_compile_error() {
	bad := "
	@[component]
	pub struct Page {}
	pub fn (p Page) view() vcsr.View {
		// label expects string, given int
		return \$vui('<main><Button label=\${42} on_click=\${noop} /></main>')
	}"
	analyze(bad) or {
		assert err.msg().contains('label')
		assert err.msg().contains('string')
		return
	}
	assert false, 'expected a prop type error'
}

fn test_missing_required_prop_is_error() {
	bad := "
	@[component]
	pub struct Page {}
	pub fn (p Page) view() vcsr.View {
		return \$vui('<main><Button on_click=\${noop} /></main>') // no label
	}"
	analyze(bad) or {
		assert err.msg().contains('missing') && err.msg().contains('label')
		return
	}
	assert false, 'expected a missing-prop error'
}

fn test_shared_component_is_hoisted_to_core() {
	// a component referenced by two or more routes must compile into core.wasm
	d := component.decide_hoist(name: 'Button', used_by_routes: ['/', '/todos'])
	assert d == HoistDecision.core
}

fn test_single_route_component_stays_local() {
	d := component.decide_hoist(name: 'ReportRow', used_by_routes: ['/reports'])
	assert d == HoistDecision.route_local
}

fn test_explicit_shared_annotation_forces_core() {
	d := component.decide_hoist(name: 'Spinner', used_by_routes: ['/'], shared: true)
	assert d == HoistDecision.core
}
