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
	text  // patch the target element's textContent
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
	expr        string           // driving expression: a sole text interpolation, or :attr value
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
pub fn compile(tree ast.Tree) !CompiledTemplate {
	if tree.root.kind == .component {
		return error('the root of a template must be an HTML element, not the component <${tree.root.tag}>: wrap it in one')
	}
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
	if node.kind == .component {
		return anchor_html // the root of a @for/@if row (the rows don't render yet)
	}
	mut s := '<' + node.tag
	for a in node.attrs {
		s += ' ${a.name}="${a.value.replace('"', '&quot;')}"'
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

	s += '>'
	if parser.is_void(node.tag) {
		return s // void elements have no children and no closing tag
	}
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
				// entities the way the skeleton's HTML parse does — decode here
				text:    if ch.kind == .interpolation {
					ch.expr
				} else {
					parser.decode_entities(ch.text)
				}
			}
		}
		sl << SlotDesc{
			kind:  .text
			path:  path.clone()
			expr:  if children.len == 1 { children[0].expr } else { '' }
			parts: parts
		}
	} else {
		mut ei := 0 // element-child index (text/anchors don't advance it)
		mut ai := 0 // anchor index among this element's comment children
		if node.tag in preserve_newline_elements && children.len > 0
			&& children[0].kind == .text && children[0].text.starts_with('\n') {
			// the browser drops a newline right after the start tag, as the
			// parser did; write one more, so the one the author kept survives
			s += '\n'
		}
		for child in children {
			match child.kind {
				.text {
					// a `<` that is text here could be markup to the browser
					// (`<?xml` is a bogus comment there, shifting the anchors);
					// <script>/<style> bodies are raw text, written as is
					s += if node.tag in raw_text_elements {
						child.text
					} else {
						child.text.replace('<', '&lt;')
					}
				}
				.comment {}
				.interpolation {
					// beside element children: its own text node, at an anchor
					sl << SlotDesc{
						kind:   .text
						path:   path.clone()
						anchor: ai
						expr:   child.expr
						parts:  [TextPart{
							is_expr: true
							text:    child.expr
						}]
					}
					s += anchor_html
					ai++
				}
				.element, .component {
					if ea := child.each {
						// @for: the row repeats; the slot lives on the container
						row := compile_node(strip_each(child))!
						sl << SlotDesc{
							kind:        .list
							path:        path.clone()
							anchor:      ai
							source_expr: ea.source_expr
							key_expr:    ea.key_expr
							row:         row
						}
						s += anchor_html
						ai++
					} else if c := child.cond {
						// @if: leave an anchor; row is the conditional content
						row := compile_node(strip_cond(child))!
						sl << SlotDesc{
							kind:      .cond
							path:      path.clone()
							anchor:    ai
							cond_expr: c.expr
							row:       row
						}
						s += anchor_html
						ai++
					} else if child.kind == .component {
						s += anchor_html // where it mounts (roadmap 7); see anchor_html
						ai++
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

// preserve_newline_elements: HTML drops a newline right after their start tag.
const preserve_newline_elements = ['pre', 'textarea', 'listing']

// raw_text_elements: HTML reads their bodies verbatim (no tags, no references).
const raw_text_elements = ['script', 'style']
