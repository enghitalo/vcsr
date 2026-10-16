// Phase 03 — Reactive binding: slot table → a binding plan.
//
// Turns the phase-02 slot table into an IR that says, per slot, how it wires to
// the reactive runtime: text/attr slots become `effect`s (re-run on a signal
// change, write to the DOM), event slots become listeners, `@bind` becomes a
// two-way binding, `@if` a conditional toggle, `@for` a keyed list. For each
// reactive expression it extracts the dependency set (`reads`) — the free
// identifiers that drive a re-run.
//
// Note: `reads` is the *candidate* dependency set (free identifiers in the
// expression). Whether each name is a signal, a computed, or a loop variable is
// resolved in phase 04 against the component struct — phase 03 has only the
// template, not the struct.
module bind

import vcsr.slots { CompiledTemplate }

pub enum BindKind {
	effect     // text / attribute: re-run on dep change, write to the DOM
	listener   // event handler
	two_way    // @bind
	cond       // @if
	keyed_list // @for
}

pub enum DomTarget {
	unset
	text_content
	value
	attribute
}

pub struct Binding {
pub mut:
	kind       BindKind
	slot       int      // index into CompiledTemplate.slots
	reads      []string // dependency set (free identifiers)
	writes_dom DomTarget
	// event
	event           string
	handler         string
	prevent_default bool
	// two-way
	dom_event string
	// keyed list
	key      string
	row_plan BindingPlan // bindings for the per-item row sub-template
}

pub struct BindingPlan {
pub mut:
	bindings []Binding
}

// uses returns true if `name` is read by any binding in this plan (helper).
pub fn (p BindingPlan) uses(name string) bool {
	for b in p.bindings {
		if name in b.reads {
			return true
		}
	}
	return false
}

// plan builds the binding plan for a compiled template.
pub fn plan(ct CompiledTemplate) !BindingPlan {
	mut bp := BindingPlan{}
	for i, s in ct.slots {
		match s.kind {
			.text {
				bp.bindings << Binding{
					kind:       .effect
					slot:       i
					reads:      idents_of(s.text_exprs())
					writes_dom: .text_content
				}
			}
			.attr {
				bp.bindings << Binding{
					kind:       .effect
					slot:       i
					reads:      free_idents(s.expr)
					writes_dom: .attribute
				}
			}
			.event {
				bp.bindings << Binding{
					kind:            .listener
					slot:            i
					event:           s.name
					handler:         s.handler
					prevent_default: 'prevent' in s.modifiers
				}
			}
			.bind {
				bp.bindings << Binding{
					kind:       .two_way
					slot:       i
					reads:      free_idents(s.target_expr)
					dom_event:  'input'
					writes_dom: .value
				}
			}
			.cond {
				bp.bindings << Binding{
					kind:     .cond
					slot:     i
					reads:    free_idents(s.cond_expr)
					row_plan: plan(s.row)!
				}
			}
			.list {
				bp.bindings << Binding{
					kind:     .keyed_list
					slot:     i
					reads:    free_idents(s.source_expr)
					key:      s.key_expr
					row_plan: plan(s.row)!
				}
			}
		}
	}
	return bp
}

// idents_of unions the free identifiers of several expressions, in order.
fn idents_of(exprs []string) []string {
	mut out := []string{}
	for e in exprs {
		for id in free_idents(e) {
			if id !in out {
				out << id
			}
		}
	}
	return out
}

// free_idents extracts the base free identifiers of an expression, in order of
// first appearance — the identifiers the component must resolve (signals,
// fields, methods) or the template must bind (@for loop variables). Member
// tails (`.x`), literals, V keywords and builtin type names are excluded;
// identifiers inside `${}` string interpolations are included.
//   'count'                -> ['count']
//   'a + b * 2'            -> ['a', 'b']
//   'user.name'            -> ['user']
//   'int(x) < 1e5'         -> ['x']
//   "'hi ${name}' + tail"  -> ['name', 'tail']
// Public so phase 04 can resolve the same candidate set against the struct.
pub fn free_idents(expr string) []string {
	mut out := []string{}
	for t in tokens(expr) {
		if t.kind == .ident && t.text !in out {
			out << t.text
		}
	}
	return out
}
