// Phase 01 — the template parser: a component's `.html` file contents → AST.
// Plain V, vcsr's own parser (no V compiler involvement). See
// ../docs/ARCHITECTURE.md and ../tests/phase_01_template_parser_test.v.
//
// HTML rules it follows: void elements (`<input>`, `<br>`, …) take no closing
// tag; `<x/>` closes any element; text runs to the next tag, so a `<` that
// doesn't start markup (`1 < 2`) and anything inside `{{ … }}` is text;
// `<script>`/`<style>` bodies are raw text. Whitespace is condensed the way
// Vue's compiler does it (see condense), except inside <pre>/<textarea>, so a
// pretty-printed template compiles to the same skeleton as a one-line one.
// Errors carry `line L, col C`.
module parser

import vcsr.ast

// void_elements never have children or a closing tag (HTML spec).
pub const void_elements = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link',
	'meta', 'param', 'source', 'track', 'wbr']

// raw_text_elements hold literal text: no tags, no interpolation, no condensing.
const raw_text_elements = ['script', 'style']

// preserve_ws_elements keep their whitespace verbatim.
const preserve_ws_elements = ['pre', 'textarea']

// is_void reports whether `tag` is an HTML void element.
pub fn is_void(tag string) bool {
	return tag.to_lower() in void_elements
}

struct Parser {
	src string
mut:
	pos      int
	preserve int // depth of <pre>/<textarea> ancestors: whitespace is kept inside them
}

// parse_template parses the contents of a `.html` template file into a Tree
// with a single root element. Identifiers in the template (`{{ x }}`,
// `@click="m"`, …) are kept verbatim; later phases resolve them against the
// component struct.
pub fn parse_template(tmpl string) !ast.Tree {
	mut p := Parser{
		src: tmpl
	}
	p.skip_ws_and_comments()
	if p.pos >= p.src.len {
		return error('empty template')
	}
	root := p.parse_element()!
	p.skip_ws_and_comments()
	if p.pos < p.src.len {
		return error('content after the root element at ${p.at(p.pos)} (a template has exactly one root element)')
	}
	return ast.Tree{
		root: root
	}
}

fn (mut p Parser) parse_element() !ast.Node {
	if p.pos >= p.src.len || p.src[p.pos] != `<` {
		return error('expected "<" at ${p.at(p.pos)}')
	}
	open := p.pos
	p.pos++ // consume '<'
	tag := p.read_name()
	if tag == '' {
		return error('expected a tag name at ${p.at(p.pos)}')
	}
	is_comp := is_component_name(tag)
	mut node := ast.Node{
		kind: if is_comp { ast.NodeKind.component } else { ast.NodeKind.element }
		tag:  tag
	}

	mut item_name := ''
	mut source_expr := ''
	mut key_expr := ''
	mut has_for := false

	for {
		p.skip_ws()
		if p.pos >= p.src.len {
			return error('unclosed tag <${tag}> opened at ${p.at(open)}')
		}
		c := p.src[p.pos]
		if c == `>` {
			p.pos++
			break
		}
		if c == `/` && p.pos + 1 < p.src.len && p.src[p.pos + 1] == `>` {
			node.self_closing = true
			p.pos += 2
			break
		}
		apos := p.pos
		aname := p.read_attr_name()
		if aname == '' {
			return error('malformed attribute in <${tag}> at ${p.at(p.pos)}')
		}
		mut aval := ''
		mut has_value := false
		p.skip_ws()
		if p.pos < p.src.len && p.src[p.pos] == `=` {
			p.pos++
			p.skip_ws()
			aval = p.read_attr_value()!
			has_value = true
		}

		// classify the attribute
		if aname.starts_with('@') {
			rest := aname[1..]
			if rest in ['bind', 'if', 'for'] || rest.len == 0 || rest.starts_with('.') {
				if aval.trim_space() == '' {
					return error('${aname} on <${tag}> needs a value at ${p.at(apos)}')
				}
			}
			if rest == 'bind' {
				node.binding = ast.Binding{
					target_expr: aval
				}
			} else if rest == 'if' {
				node.cond = ast.Cond{
					expr: aval
				}
			} else if rest == 'for' {
				has_for = true
				item_name, source_expr = split_for(aval) or {
					return error('malformed @for "${aval}" at ${p.at(apos)} (expected "item in source")')
				}
			} else {
				ev := rest.split('.')
				if ev[0] == '' || !has_value || aval.trim_space() == '' {
					return error('event ${aname} on <${tag}> needs a handler, e.g. ${aname}="method", at ${p.at(apos)}')
				}
				node.events << ast.Event{
					name:         ev[0]
					modifiers:    if ev.len > 1 { ev[1..] } else { []string{} }
					handler_expr: aval
				}
			}
		} else if aname.starts_with('class:') {
			if aname.len == 6 || aval.trim_space() == '' {
				return error('${aname} on <${tag}> needs a class name and a condition, e.g. class:active="on", at ${p.at(apos)}')
			}
			node.class_bindings << ast.ClassBinding{
				name: aname[6..]
				expr: aval
			}
		} else if aname.starts_with(':') {
			rest := aname[1..]
			if rest == '' || aval.trim_space() == '' {
				return error('bound attribute ${aname} on <${tag}> needs a name and an expression at ${p.at(apos)}')
			}
			if rest == 'key' {
				key_expr = aval
			} else if is_comp {
				node.props << ast.Prop{
					name:  rest
					bound: true
					expr:  aval
				}
			} else {
				node.attr_bindings << ast.AttrBinding{
					name: rest
					expr: aval
				}
			}
		} else {
			if is_comp {
				node.props << ast.Prop{
					name:  aname
					bound: false
					value: aval
				}
			} else {
				node.attrs << ast.Attr{
					name:  aname
					value: aval
				}
			}
		}
	}

	if has_for {
		node.each = ast.Each{
			item_name:   item_name
			source_expr: source_expr
			key_expr:    key_expr
		}
	}

	if node.self_closing || is_void(tag) {
		return node
	}
	lower := tag.to_lower()
	if lower in raw_text_elements {
		p.parse_raw_text(mut node, open)!
		return node
	}
	keep := lower in preserve_ws_elements
	if keep {
		p.preserve++
	}
	p.parse_children(mut node, open)!
	if keep {
		p.preserve--
	}
	return node
}

// split_for splits an @for value `item in source` on whitespace around `in`;
// `item` must be a plain identifier.
fn split_for(v string) ?(string, string) {
	f := v.fields()
	if f.len < 3 || f[1] != 'in' || !is_ident(f[0]) {
		return none
	}
	return f[0], f[2..].join(' ')
}

fn (mut p Parser) parse_children(mut parent ast.Node, open int) ! {
	for {
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}> opened at ${p.at(open)}')
		}
		// text runs to the next tag: skip over {{ … }} (it may contain `<`) and
		// any `<` that doesn't start markup (`a < b`)
		start := p.pos
		for p.pos < p.src.len {
			if p.starts_with('{{{{') || p.starts_with('}}}}') {
				p.pos += 4
				continue
			}
			if p.starts_with('{{') {
				close := p.find('}}', p.pos + 2)
				if close < 0 {
					return error('unterminated {{ at ${p.at(p.pos)} (missing }})')
				}
				p.pos = close + 2
				continue
			}
			if p.src[p.pos] == `<` && p.starts_markup() {
				break
			}
			p.pos++
		}
		if p.pos > start {
			flush_text(mut parent, p.src[start..p.pos])
		}
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}> opened at ${p.at(open)}')
		}
		// at '<'
		if p.starts_with('<!--') {
			end := p.find('-->', p.pos)
			text := if end < 0 { p.src[p.pos + 4..] } else { p.src[p.pos + 4..end] }
			parent.children << ast.Node{
				kind: .comment
				text: text
			}
			p.pos = if end < 0 { p.src.len } else { end + 3 }
			continue
		}
		if p.starts_with('</') {
			cpos := p.pos
			p.pos += 2
			cname := p.read_name()
			p.skip_ws()
			if p.pos >= p.src.len || p.src[p.pos] != `>` {
				return error('unclosed closing tag for <${parent.tag}> at ${p.at(cpos)}')
			}
			p.pos++
			if cname != parent.tag {
				return error('mismatched closing tag </${cname}> at ${p.at(cpos)}, expected </${parent.tag}> (opened at ${p.at(open)})')
			}
			if p.preserve == 0 {
				parent.children = condense(parent.children)
			}
			return
		}
		child := p.parse_element()!
		parent.children << child
	}
}

// parse_raw_text reads a <script>/<style> body verbatim up to its closing tag.
fn (mut p Parser) parse_raw_text(mut node ast.Node, open int) ! {
	close := '</' + node.tag
	end := p.find(close, p.pos)
	if end < 0 {
		return error('unclosed tag <${node.tag}> opened at ${p.at(open)}')
	}
	if end > p.pos {
		node.children << ast.Node{
			kind: .text
			text: p.src[p.pos..end]
		}
	}
	p.pos = end + close.len
	p.skip_ws()
	if p.pos >= p.src.len || p.src[p.pos] != `>` {
		return error('unclosed closing tag for <${node.tag}> at ${p.at(end)}')
	}
	p.pos++
}

// condense applies Vue's "condense" whitespace rule to one element's children:
// a whitespace-only text node is removed when it is the first or last child,
// or sits between two elements/comments and contains a newline; otherwise it
// becomes a single space. Other text has its whitespace runs collapsed to one
// space. So indentation between tags vanishes, while `a <b>x</b> c` keeps its
// spaces.
fn condense(children []ast.Node) []ast.Node {
	mut out := []ast.Node{cap: children.len}
	for i, ch in children {
		if ch.kind != .text {
			out << ch
			continue
		}
		if is_blank(ch.text) {
			first := i == 0
			last := i == children.len - 1
			between_tags := !first && !last && is_tag_like(children[i - 1])
				&& is_tag_like(children[i + 1])
			if first || last || (between_tags && ch.text.contains_any('\n\r')) {
				continue
			}
			out << ast.Node{
				kind: .text
				text: ' '
			}
			continue
		}
		out << ast.Node{
			kind: .text
			text: collapse_ws(ch.text)
		}
	}
	return out
}

fn is_tag_like(n ast.Node) bool {
	return n.kind in [.element, .component, .comment]
}

fn is_blank(s string) bool {
	for c in s {
		if !is_ws(c) {
			return false
		}
	}
	return true
}

fn collapse_ws(s string) string {
	mut out := []u8{cap: s.len}
	mut in_ws := false
	for c in s {
		if is_ws(c) {
			if !in_ws {
				out << ` `
			}
			in_ws = true
		} else {
			out << c
			in_ws = false
		}
	}
	return out.bytestr()
}

// flush_text splits raw text into .text and .interpolation child nodes,
// handling `{{ expr }}` and the `{{{{` / `}}}}` literal-brace escapes. (The
// caller has already checked every `{{` is terminated.)
fn flush_text(mut parent ast.Node, raw string) {
	mut out := ''
	mut i := 0
	mut seg := 0
	for i < raw.len {
		if i + 4 <= raw.len && raw[i..i + 4] == '{{{{' {
			out += raw[seg..i] + '{{'
			i += 4
			seg = i
		} else if i + 4 <= raw.len && raw[i..i + 4] == '}}}}' {
			out += raw[seg..i] + '}}'
			i += 4
			seg = i
		} else if i + 2 <= raw.len && raw[i..i + 2] == '{{' {
			out += raw[seg..i]
			if out.len > 0 {
				parent.children << ast.Node{
					kind: .text
					text: out
				}
				out = ''
			}
			close := index_of(raw, '}}', i + 2)
			parent.children << ast.Node{
				kind: .interpolation
				expr: raw[i + 2..close].trim_space()
			}
			i = close + 2
			seg = i
		} else {
			i++
		}
	}
	out += raw[seg..]
	if out.len > 0 {
		parent.children << ast.Node{
			kind: .text
			text: out
		}
	}
}

// --- lexical helpers --------------------------------------------------------

// starts_markup reports whether the `<` at pos begins a tag, closing tag or
// comment (HTML: `<` followed by a letter, `/` or `!`); otherwise it is text.
fn (p &Parser) starts_markup() bool {
	if p.pos + 1 >= p.src.len {
		return false
	}
	n := p.src[p.pos + 1]
	return (n >= `a` && n <= `z`) || (n >= `A` && n <= `Z`) || n == `/` || n == `!`
}

// at renders a byte offset as `line L, col C` (1-based) for error messages.
fn (p &Parser) at(pos int) string {
	mut line := 1
	mut col := 1
	for i := 0; i < pos && i < p.src.len; i++ {
		if p.src[i] == `\n` {
			line++
			col = 1
		} else {
			col++
		}
	}
	return 'line ${line}, col ${col}'
}

fn (mut p Parser) skip_ws() {
	for p.pos < p.src.len && is_ws(p.src[p.pos]) {
		p.pos++
	}
}

fn (mut p Parser) skip_ws_and_comments() {
	for p.pos < p.src.len {
		if is_ws(p.src[p.pos]) {
			p.pos++
		} else if p.starts_with('<!--') {
			end := p.find('-->', p.pos)
			p.pos = if end < 0 { p.src.len } else { end + 3 }
		} else {
			break
		}
	}
}

fn (mut p Parser) read_name() string {
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
			|| c == `-` || c == `_` {
			p.pos++
		} else {
			break
		}
	}
	return p.src[start..p.pos]
}

fn (mut p Parser) read_attr_name() string {
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if is_ws(c) || c == `=` || c == `>` || c == `/` {
			break
		}
		p.pos++
	}
	return p.src[start..p.pos]
}

fn (mut p Parser) read_attr_value() !string {
	if p.pos >= p.src.len {
		return error('expected an attribute value at ${p.at(p.pos)}')
	}
	q := p.src[p.pos]
	if q == `"` || q == `'` {
		open := p.pos
		p.pos++ // opening quote
		start := p.pos
		for p.pos < p.src.len && p.src[p.pos] != q {
			p.pos++
		}
		if p.pos >= p.src.len {
			return error('unterminated attribute value starting at ${p.at(open)}')
		}
		val := p.src[start..p.pos]
		p.pos++ // closing quote
		return val
	}
	// unquoted value: up to whitespace or `>` (HTML) — `/` is allowed (`href=/a/b`),
	// except as the `/>` that self-closes the tag
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if is_ws(c) || c == `>` || (c == `/` && p.pos + 1 < p.src.len && p.src[p.pos + 1] == `>`) {
			break
		}
		p.pos++
	}
	return p.src[start..p.pos]
}

fn (p &Parser) starts_with(s string) bool {
	return p.pos + s.len <= p.src.len && p.src[p.pos..p.pos + s.len] == s
}

fn (p &Parser) find(sub string, from int) int {
	return index_of(p.src, sub, from)
}

fn index_of(s string, sub string, from int) int {
	mut i := from
	for i + sub.len <= s.len {
		if s[i..i + sub.len] == sub {
			return i
		}
		i++
	}
	return -1
}

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

fn is_ident(s string) bool {
	if s == '' || !((s[0] >= `a` && s[0] <= `z`) || (s[0] >= `A` && s[0] <= `Z`) || s[0] == `_`) {
		return false
	}
	for c in s {
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`) {
			return false
		}
	}
	return true
}

fn is_component_name(tag string) bool {
	return tag.len > 0 && tag[0] >= `A` && tag[0] <= `Z`
}
