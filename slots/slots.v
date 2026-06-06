// Phase 02 — Slot extraction: AST → static HTML skeleton + slot table.
//
// Splits a parsed template into (a) a STATIC HTML string with the dynamic
// content emptied out (this is what gets embedded in the WASM data segment and
// registered once as a <template>), and (b) a SLOT TABLE describing where the
// dynamic holes are: an element-child-index `path` from the clone root, the slot
// `kind`, and the driving expression. Plain V; consumes the phase-01 AST.
module slots

import vcsr.ast

pub enum SlotKind {
	text  // patch the target element's textContent
	attr  // patch an attribute (`name`)
	event // addEventListener(`name`)
	bind  // two-way bind to `target_expr`
	cond  // @if: a `<!--vcsr:if-->` anchor; `row` is the conditional content
	list  // @for: `row` is the per-item sub-template, keyed by `key_expr`
}

pub struct SlotDesc {
pub mut:
	kind        SlotKind
	path        []int            // element-child-index path from the clone root
	name        string           // attr/event name
	expr        string           // driving expression: text interpolation, or :attr value
	target_expr string           // @bind target
	cond_expr   string           // @if condition
	source_expr string           // @for source (the `items` in `item in items`)
	key_expr    string           // @for :key
	handler     string           // @event handler expression
	modifiers   []string         // @event modifiers, e.g. ['prevent']
	row         CompiledTemplate // sub-template for cond/list
}

pub struct CompiledTemplate {
pub mut:
	html  string
	slots []SlotDesc
}

// compile turns a parsed template Tree into its static skeleton + slot table.
pub fn compile(tree ast.Tree) !CompiledTemplate {
	return compile_node(tree.root)!
}

fn compile_node(root ast.Node) !CompiledTemplate {
	mut sl := []SlotDesc{}
	html := serialize(root, []int{}, mut sl)!
	return CompiledTemplate{
		html:  html
		slots: sl
	}
}

// serialize emits the static HTML for `node` (placed at `path`) and appends any
// slots it contributes to `sl`.
fn serialize(node ast.Node, path []int, mut sl []SlotDesc) !string {
	mut s := '<' + node.tag
	for a in node.attrs {
		s += ' ${a.name}="${a.value}"'
	}
	// the node's own dynamic bindings become slots keyed to this element
	for ev in node.events {
		sl << SlotDesc{
			kind:      .event
			path:      path.clone()
			name:      ev.name
			handler:   ev.handler_expr
			modifiers: ev.modifiers
		}
	}
	if b := node.binding {
		sl << SlotDesc{
			kind:        .bind
			path:        path.clone()
			target_expr: b.target_expr
		}
	}
	for ab in node.attr_bindings {
		sl << SlotDesc{
			kind: .attr
			path: path.clone()
			name: ab.name
			expr: ab.expr
		}
	}

	if node.self_closing {
		s += '>'
		return s
	}
	s += '>'

	// a single interpolation child => set this element's textContent
	if node.children.len == 1 && node.children[0].kind == .interpolation {
		sl << SlotDesc{
			kind: .text
			path: path.clone()
			expr: node.children[0].expr
		}
	} else {
		mut ei := 0 // element-child index (text/interpolation don't advance it)
		for child in node.children {
			match child.kind {
				.text {
					s += child.text
				}
				.interpolation {
					return error('mixed static text and interpolation in <${node.tag}> is not supported yet (phase 02 handles one interpolation as an element\'s sole child)')
				}
				.element, .component {
					if ea := child.each {
						// @for: the row repeats; the slot lives on the container
						row := compile_node(strip_each(child))!
						sl << SlotDesc{
							kind:        .list
							path:        path.clone()
							source_expr: ea.source_expr
							key_expr:    ea.key_expr
							row:         row
						}
					} else if c := child.cond {
						// @if: leave an anchor; row is the conditional content
						row := compile_node(strip_cond(child))!
						sl << SlotDesc{
							kind:      .cond
							path:      path.clone()
							cond_expr: c.expr
							row:       row
						}
						s += '<!--vcsr:if-->'
					} else {
						mut cp := path.clone()
						cp << ei
						s += serialize(child, cp, mut sl)!
						ei++
					}
				}
			}
		}
	}

	s += '</' + node.tag + '>'
	return s
}

fn strip_each(node ast.Node) ast.Node {
	mut c := node
	c.each = none
	return c
}

fn strip_cond(node ast.Node) ast.Node {
	mut c := node
	c.cond = none
	return c
}
