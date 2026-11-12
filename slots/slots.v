// Phase 02 — Slot extraction: AST → static HTML skeleton + slot table.
//
// Splits a parsed template into (a) a STATIC HTML string with the dynamic
// content emptied out (this is what gets embedded in the WASM data segment and
// registered once as a <template>), and (b) a SLOT TABLE describing where the
// dynamic holes are: an element-child-index `path` from the clone root, the slot
// `kind`, and the driving expression. Plain V; consumes the phase-01 AST.
module slots

import vcsr.ast
import vcsr.parser

pub enum SlotKind {
	text  // patch an element's textContent, or the text node at an anchor
	attr  // patch an attribute (`name`)
	event // addEventListener(`name`)
	bind  // two-way bind to `target_expr`
	cond  // @if: an anchor comment; `row` is the conditional content
	list  // @for: `row` is the per-item sub-template, keyed by `key_expr`
}

// TextPart is one piece of a text slot: literal text, or an expression whose
// value is rendered in its place.
pub struct TextPart {
pub:
	is_expr bool
	text    string // the literal text, or the expression source
}

// ANCHORS. Some holes aren't an element: a conditional block, a list, or an
// interpolation that sits between element children. Each leaves an empty
// comment `<!---->` in the skeleton (user comments never reach the skeleton, so
// every comment there is an anchor), and its slot is addressed as `path` (the
// container element) + `anchor` (which of the container's comment children).
// A child component leaves one too: its tag never reaches the browser's parser
// (which would read `<Link>` as a void <link>), and until child components
// render (roadmap 7) the anchor marks where it mounts.
pub const anchor_html = '<!---->'

pub struct SlotDesc {
pub mut:
	kind        SlotKind
	path        []int // element-child-index path from the clone root
	anchor      int = -1 // >= 0: the slot is the container's anchor-th comment child
	name        string           // attr/event name
	expr        string           // :attr expression
	parts       []TextPart       // text slots: literal text + expressions, concatenated
	target_expr string           // @bind target
	cond_expr   string           // @if condition
	source_expr string           // @for source (the `items` in `item in items`)
	key_expr    string           // @for :key
	handler     string           // @event handler expression
	modifiers   []string         // @event modifiers, e.g. ['prevent']
	row         CompiledTemplate // sub-template for cond/list
}

// text_exprs lists the expressions a text slot renders.
pub fn (s SlotDesc) text_exprs() []string {
	return s.parts.filter(it.is_expr).map(it.text)
}

pub struct CompiledTemplate {
pub mut:
	html  string
	slots []SlotDesc
}

// compile turns a parsed template Tree into its static skeleton + slot table.
// The root is what the runtime clones and mounts, so it must be a plain HTML
// element: not a component, and not conditional or repeated.
pub fn compile(tree ast.Tree) !CompiledTemplate {
	root := tree.root
	if root.kind == .component {
		return error('the root of a template must be an HTML element, not the component <${root.tag}>: wrap it in one')
	}
	if root.cond != none || root.each != none {
		return error('the root element <${root.tag}> of a template cannot have @if or @for: wrap it in an element')
	}
	return compile_node(root)!
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
	if node.kind == .component {
		return anchor_html // the root of a @for/@if row (the rows don't render yet)
	}
	mut s := '<' + node.tag
	for a in node.attrs {
		s += ' ${a.name}="${a.value.replace('"', '&quot;')}"'
	}
	// the node's own dynamic bindings become slots keyed to this element; @bind
	// first, so its writer runs before an @input handler on the same element
	if b := node.binding {
		sl << SlotDesc{
			kind:        .bind
			path:        path.clone()
			target_expr: b.target_expr
		}
	}
	for ev in node.events {
		sl << SlotDesc{
			kind:      .event
			path:      path.clone()
			name:      ev.name
			handler:   ev.handler_expr
			modifiers: ev.modifiers
		}
	}
	for ab in node.attr_bindings {
		sl << SlotDesc{
			kind: .attr
			path: path.clone()
			// setAttribute lowercases an HTML attribute's name; SVG's keep their case
			name: if node.foreign { ab.name } else { ab.name.to_lower() }
			expr: ab.expr
		}
	}

	s += '>'
	if parser.is_void(node.tag) {
		return s // void elements have no children and no closing tag
	}
	tag := node.tag.to_lower()
	first_slot := sl.len
	children := node.children.filter(it.kind != .comment) // user comments don't ship
	has_interp := children.any(it.kind == .interpolation)
	only_text := children.all(it.kind in [.text, .interpolation])
	if has_interp && only_text {
		// text and interpolations only: ONE text slot sets the element's
		// textContent to their concatenation
		mut parts := []TextPart{}
		for ch in children {
			parts << TextPart{
				is_expr: ch.kind == .interpolation
				// literal text is set via textContent, which doesn't decode
				// references the way the skeleton's HTML parse does — decode
				// here (a raw-text body has none)
				text:    if ch.kind == .interpolation {
					ch.expr
				} else if node.raw_text {
					ch.text
				} else {
					parser.decode_entities(ch.text)
				}
			}
		}
		sl << SlotDesc{
			kind:  .text
			path:  path.clone()
			parts: parts
		}
	} else {
		mut ei := 0 // element-child index (text/anchors don't advance it)
		mut ai := 0 // anchor index among this element's comment children
		if !node.foreign && tag in parser.newline_elements && children.len > 0
			&& children[0].kind == .text
			&& parser.decode_entities(children[0].text).starts_with('\n') {
			// the browser drops a newline right after the start tag, as the
			// parser did; write one more, so the one the author kept survives
			s += '\n'
		}
		for child in children {
			if child.kind == .text {
				// a `<` that is text here could be markup to the browser
				// (`<?xml` is a bogus comment there, shifting the anchors); a
				// raw-text body is written as is
				s += if node.raw_text { child.text } else { child.text.replace('<', '&lt;') }
				continue
			}
			if child.kind == .element && child.each == none && child.cond == none {
				mut cp := path.clone()
				cp << ei
				s += serialize(child, cp, mut sl)!
				ei++
				continue
			}
			// everything else leaves an anchor comment: an interpolation beside
			// elements (its own text node), @for, @if, and a child component
			if child.kind == .interpolation {
				sl << SlotDesc{
					kind:   .text
					path:   path.clone()
					anchor: ai
					parts:  [TextPart{
						is_expr: true
						text:    child.expr
					}]
				}
			} else if ea := child.each {
				// @for: the row repeats at the anchor
				sl << SlotDesc{
					kind:        .list
					path:        path.clone()
					anchor:      ai
					source_expr: ea.source_expr
					key_expr:    ea.key_expr
					row:         compile_node(strip_each(child))!
				}
			} else if c := child.cond {
				// @if: the row is the conditional content
				sl << SlotDesc{
					kind:      .cond
					path:      path.clone()
					anchor:    ai
					cond_expr: c.expr
					row:       compile_node(strip_cond(child))!
				}
			} // a component: where it mounts (roadmap 7); see anchor_html
			s += anchor_html
			ai++
		}
	}
	if tag == 'template' && sl.len > first_slot {
		return error('<template> cannot hold bindings: the browser parses its content into an inert fragment the runtime cannot reach')
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
