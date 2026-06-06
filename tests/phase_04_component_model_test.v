// Phase 04 — Component model: pair the file triplet, resolve refs, EMIT PLAIN V.
//
// GOAL: a component is three co-located files sharing a basename — `name.v`
// (logic: the @[component] struct + signals + handlers), `name.html` (template),
// `name.css` (styles, optional). vcsr pairs them, resolves the template's
// references against the struct's fields/methods, and GENERATES `name.gen.v`:
// plain V implementing `view()`/`style()` that imports only the vcsr runtime.
//
// This phase is where "no V compiler changes" is enforced: the generated output
// must contain NO `$vui`/`$css`/`$`-builtins — just ordinary V.
// See ../docs/ARCHITECTURE.md.
module main

import vcsr.component { HoistDecision, analyze }

// A component fixture: the three files' contents. `analyze` is what vcsr does
// after reading them off disk (paired by basename).
const counter_v = '
@[component]
pub struct Counter {
	vcsr.Component
mut:
	count vcsr.Signal[int] = signal(0)
}
pub fn (mut c Counter) inc() { c.count.update(fn (n int) int { return n + 1 }) }
'
const counter_html = '<main class="counter"><h1>{{ count }}</h1><button @click="inc">+1</button></main>'
const counter_css = '.counter { display: grid; } .muted { color: #888; }'

fn counter() component.Component {
	return analyze(
		v:    counter_v
		html: counter_html
		css:  counter_css
	) or { panic(err) }
}

// --- pairing + struct analysis ---------------------------------------------

fn test_extracts_struct_and_fields() {
	c := counter()
	assert c.name == 'Counter'
	assert c.signal_field('count')!.typ == 'int'
	assert c.has_method('inc')
}

fn test_template_refs_resolve_against_struct() {
	c := counter()
	// {{ count }} resolves to the `count` signal field; @click="inc" to the method
	assert c.resolves_ref('count')
	assert c.resolves_handler('inc')
}

fn test_unknown_reference_is_compile_error() {
	analyze(v: counter_v, html: '<h1>{{ nope }}</h1>', css: '') or {
		assert err.msg().contains('nope') && err.msg().contains('Counter')
		return
	}
	assert false, 'expected an unknown-reference error'
}

fn test_unknown_handler_is_compile_error() {
	analyze(v: counter_v, html: '<button @click="missing">x</button>', css: '') or {
		assert err.msg().contains('missing')
		return
	}
	assert false, 'expected an unknown-handler error'
}

fn test_missing_html_file_is_error() {
	analyze(v: counter_v, html: '', css: '') or {
		assert err.msg().contains('template')
		return
	}
	assert false, 'expected a missing-template error'
}

// --- codegen: PLAIN V, no compiler builtins --------------------------------

fn test_emits_gen_v_with_view_and_style() {
	gen := counter().codegen()!
	assert gen.filename == 'counter.gen.v'
	assert gen.source.contains('fn (mut c Counter) view() vcsr.View')
	assert gen.source.contains('fn (c Counter) style() string')
}

fn test_generated_code_has_no_compiler_builtins() {
	// the whole point of the file-based design: NO $vui / $css / $-builtins
	src := counter().codegen()!.source
	assert !src.contains('\$vui')
	assert !src.contains('\$css')
	assert !src.contains('\$') // no comptime builtin of any kind
}

fn test_generated_code_imports_only_runtime() {
	src := counter().codegen()!.source
	assert src.contains('import vcsr.runtime')
	// it must compile with stock V — no special compiler support
	assert counter().codegen()!.compiles_with_stock_v
}

fn test_generated_view_embeds_static_skeleton() {
	src := counter().codegen()!.source
	// the static HTML skeleton is embedded as a plain string constant
	assert src.contains("'<main class=\"counter\"><h1></h1><button>+1</button></main>'")
}

fn test_style_is_scoped_in_generated_code() {
	src := counter().codegen()!.source
	// `.counter`/`.muted` are rewritten to component-scoped names (phase 05)
	assert !src.contains("'.counter {") // not the raw selector
	assert src.contains('counter_') // scoped
}

// --- composition + hoisting -------------------------------------------------

fn test_detects_child_composition() {
	c := analyze(
		v:    '@[component]\npub struct Page { vcsr.Component }'
		html: '<main><Button :label="ok" @click="noop" /></main>'
		css:  ''
	)!
	assert 'Button' in c.children
}

fn test_shared_component_is_hoisted_to_core() {
	d := component.decide_hoist(name: 'Button', used_by_routes: ['/', '/todos'])
	assert d == HoistDecision.core
}

fn test_single_route_component_stays_local() {
	d := component.decide_hoist(name: 'ReportRow', used_by_routes: ['/reports'])
	assert d == HoistDecision.route_local
}
