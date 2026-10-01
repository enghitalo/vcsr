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
				text:    if ch.kind == .interpolation { ch.expr } else { decode_entities(ch.text) }
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
		for child in children {
			match child.kind {
				.text {
					s += child.text
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

// named_entities maps the HTML character references templates commonly use.
const named_entities = {
	'amp':    '&'
	'lt':     '<'
	'gt':     '>'
	'quot':   '"'
	'apos':   "'"
	'nbsp':   '\u00a0'
	'copy':   '©'
	'reg':    '®'
	'trade':  '™'
	'hellip': '…'
	'mdash':  '—'
	'ndash':  '–'
	'middot': '·'
	'bull':   '•'
	'times':  '×'
	'divide': '÷'
	'deg':    '°'
	'euro':   '€'
	'laquo':  '«'
	'raquo':  '»'
	'larr':   '←'
	'rarr':   '→'
	'uarr':   '↑'
	'darr':   '↓'
	'hearts': '♥'
	'check':  '✓'
}

// decode_entities turns HTML character references (`&amp;`, `&#169;`,
// `&#x1F600;`) into the characters they name; an unknown or malformed `&…`
// is left as written, like a browser does.
pub fn decode_entities(s string) string {
	if !s.contains('&') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		if s[i] == `&` {
			semi := s.index_after(';', i + 1) or { -1 }
			if semi > i + 1 && semi - i <= 12 {
				name := s[i + 1..semi]
				mut decoded := ''
				if name.starts_with('#x') || name.starts_with('#X') {
					decoded = codepoint_str(u32(('0x' + name[2..]).parse_uint(0, 32) or { 0 }))
				} else if name.starts_with('#') {
					decoded = codepoint_str(u32(name[1..].parse_uint(10, 32) or { 0 }))
				} else {
					decoded = named_entities[name] or { '' }
				}
				if decoded != '' {
					out << decoded.bytes()
					i = semi + 1
					continue
				}
			}
		}
		out << s[i]
		i++
	}
	return out.bytestr()
}

fn codepoint_str(cp u32) string {
	if cp == 0 || cp > 0x10FFFF {
		return ''
	}
	return rune(cp).str()
}
