// Phase 01 — the template parser: a component's `.html` file contents → AST.
// Plain V, vcsr's own parser (no V compiler involvement). See
// ../docs/ARCHITECTURE.md and ../tests/phase_01_template_parser_test.v.
module parser

import vcsr.ast

struct Parser {
	src string
mut:
	pos int
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
	return ast.Tree{
		root: root
	}
}

fn (mut p Parser) parse_element() !ast.Node {
	if p.pos >= p.src.len || p.src[p.pos] != `<` {
		return error('expected "<" at position ${p.pos}')
	}
	p.pos++ // consume '<'
	tag := p.read_name()
	if tag == '' {
		return error('expected a tag name at position ${p.pos}')
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
			return error('unclosed tag <${tag}>')
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
		aname := p.read_attr_name()
		if aname == '' {
			return error('malformed attribute in <${tag}> at position ${p.pos}')
		}
		mut aval := ''
		p.skip_ws()
		if p.pos < p.src.len && p.src[p.pos] == `=` {
			p.pos++
			p.skip_ws()
			aval = p.read_attr_value()!
		}

		// classify the attribute
		if aname.starts_with('@') {
			rest := aname[1..]
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
				parts := aval.split(' in ')
				if parts.len == 2 {
					item_name = parts[0].trim_space()
					source_expr = parts[1].trim_space()
				} else {
					return error('malformed @for "${aval}" (expected "item in source")')
				}
			} else {
				ev := rest.split('.')
				node.events << ast.Event{
					name:         ev[0]
					modifiers:    if ev.len > 1 { ev[1..] } else { []string{} }
					handler_expr: aval
				}
			}
		} else if aname.starts_with('class:') {
			node.class_bindings << ast.ClassBinding{
				name: aname[6..]
				expr: aval
			}
		} else if aname.starts_with(':') {
			rest := aname[1..]
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

	if !node.self_closing {
		p.parse_children(mut node)!
	}
	return node
}

fn (mut p Parser) parse_children(mut parent ast.Node) ! {
	for {
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}>')
		}
		// accumulate raw text up to the next '<' (slice keeps UTF-8 intact)
		start := p.pos
		for p.pos < p.src.len && p.src[p.pos] != `<` {
			p.pos++
		}
		if p.pos > start {
			flush_text(mut parent, p.src[start..p.pos])
		}
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}>')
		}
		// at '<'
		if p.starts_with('<!--') {
			end := p.find('-->', p.pos)
			p.pos = if end < 0 { p.src.len } else { end + 3 }
			continue
		}
		if p.starts_with('</') {
			p.pos += 2
			cname := p.read_name()
			p.skip_ws()
			if p.pos >= p.src.len || p.src[p.pos] != `>` {
				return error('unclosed closing tag for <${parent.tag}>')
			}
			p.pos++
			if cname != parent.tag {
				return error('mismatched closing tag </${cname}>, expected </${parent.tag}>')
			}
			return
		}
		child := p.parse_element()!
		parent.children << child
	}
}

// flush_text splits raw text into .text and .interpolation child nodes,
// handling `{{ expr }}` and the `{{{{` / `}}}}` literal-brace escapes.
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
			if close < 0 {
				seg = i // unterminated: treat the rest as text
				i = raw.len
			} else {
				parent.children << ast.Node{
					kind: .interpolation
					expr: raw[i + 2..close].trim_space()
				}
				i = close + 2
				seg = i
			}
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

fn (mut p Parser) skip_ws() {
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
			p.pos++
		} else {
			break
		}
	}
}

fn (mut p Parser) skip_ws_and_comments() {
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
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
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == `=` || c == `>` || c == `/` {
			break
		}
		p.pos++
	}
	return p.src[start..p.pos]
}

fn (mut p Parser) read_attr_value() !string {
	if p.pos >= p.src.len {
		return error('expected an attribute value')
	}
	q := p.src[p.pos]
	if q == `"` || q == `'` {
		p.pos++ // opening quote
		start := p.pos
		for p.pos < p.src.len && p.src[p.pos] != q {
			p.pos++
		}
		if p.pos >= p.src.len {
			return error('unterminated attribute value')
		}
		val := p.src[start..p.pos]
		p.pos++ // closing quote
		return val
	}
	// unquoted value
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == `>` || c == `/` {
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

fn is_component_name(tag string) bool {
	return tag.len > 0 && tag[0] >= `A` && tag[0] <= `Z`
}
