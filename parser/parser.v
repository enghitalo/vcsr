// Phase 01 — the template parser: a component's `.html` file contents → AST.
// Plain V, vcsr's own parser (no V compiler involvement). See
// ../docs/ARCHITECTURE.md and ../tests/phase_01_template_parser_test.v.
//
// HTML rules it follows: void elements (`<input>`, `<br>`, …) take no closing
// tag; `<x/>` closes any element; text runs to the next tag, so a `<` that
// doesn't start markup (`1 < 2`) and anything inside `{{ … }}` is text; the
// body of a raw-text element (`<script>`, `<style>`, …) or of `<textarea>`/
// `<title>` is text (a template may still interpolate in it), never markup;
// newlines are normalized to LF, and one right after `<pre>`/`<textarea>`/
// `<listing>` is dropped. Inside `<svg>`/`<math>` (foreign content) those
// element rules don't apply. They are HTML's rules, so they apply to elements
// only: a PascalCase tag is a component whatever its name (`<Link>` is not a
// void `<link>`), while HTML written in capitals (`<BR>`, `<TABLE>`) is HTML.
// Whitespace is condensed the way Vue's compiler does it (see condense),
// except inside <pre>/<textarea>/<listing>, so a pretty-printed template
// compiles to the same skeleton as a one-line one. Errors carry `line L, col C`.
//
// parse_html parses a compiled SKELETON the way the browser does, for the
// native mock DOM: no `{{ }}`, no directives, no whitespace condensing, tag and
// attribute names lowercased (outside svg/math), the first of two same-named
// attributes kept, and character references decoded.
module parser

import strings
import vcsr.ast

// void_elements never have children or a closing tag (HTML spec, including the
// legacy ones a browser still parses as void).
pub const void_elements = ['area', 'base', 'basefont', 'bgsound', 'br', 'col', 'embed', 'frame',
	'hr', 'img', 'input', 'keygen', 'link', 'meta', 'param', 'source', 'track', 'wbr']

// raw_text_elements' bodies are literal text: no tags and no character
// references (vcsr still reads `{{ }}` in them).
pub const raw_text_elements = ['script', 'style', 'xmp', 'iframe', 'noembed', 'noframes']

// rcdata_elements' bodies are text with character references, but no tags.
pub const rcdata_elements = ['textarea', 'title']

// newline_elements drop a newline right after their start tag, and keep their
// whitespace verbatim.
pub const newline_elements = ['pre', 'textarea', 'listing']

// html_elements are HTML's element names: written in capitals (`<BR>`), they
// are still HTML, not components (HTML tag names are case-insensitive).
const html_elements = ['a', 'abbr', 'acronym', 'address', 'area', 'article', 'aside', 'audio',
	'b', 'base', 'basefont', 'bdi', 'bdo', 'bgsound', 'big', 'blink', 'blockquote', 'body', 'br',
	'button', 'canvas', 'caption', 'center', 'cite', 'code', 'col', 'colgroup', 'data', 'datalist',
	'dd', 'del', 'details', 'dfn', 'dialog', 'dir', 'div', 'dl', 'dt', 'em', 'embed', 'fieldset',
	'figcaption', 'figure', 'font', 'footer', 'form', 'frame', 'frameset', 'h1', 'h2', 'h3', 'h4',
	'h5', 'h6', 'head', 'header', 'hgroup', 'hr', 'html', 'i', 'iframe', 'image', 'img', 'input',
	'ins', 'kbd', 'keygen', 'label', 'legend', 'li', 'link', 'listing', 'main', 'map', 'mark',
	'marquee', 'math', 'menu', 'meta', 'meter', 'nav', 'nobr', 'noembed', 'noframes', 'noscript',
	'object', 'ol', 'optgroup', 'option', 'output', 'p', 'param', 'picture', 'plaintext', 'pre',
	'progress', 'q', 'rb', 'rp', 'rt', 'rtc', 'ruby', 's', 'samp', 'script', 'search', 'section',
	'select', 'slot', 'small', 'source', 'span', 'strike', 'strong', 'style', 'sub', 'summary',
	'sup', 'svg', 'table', 'tbody', 'td', 'template', 'textarea', 'tfoot', 'th', 'thead', 'time',
	'title', 'tr', 'track', 'tt', 'u', 'ul', 'var', 'video', 'wbr', 'xmp']

// is_void reports whether `tag` is an HTML void element (never a component).
pub fn is_void(tag string) bool {
	return !is_component_name(tag) && lower(tag) in void_elements
}

struct Parser {
	src  string
	html bool // HTML mode (parse_html): a skeleton, read the way a browser reads it
mut:
	pos      int
	preserve int // depth of <pre>/<textarea>/<listing> ancestors: whitespace is kept inside them
	foreign  int // depth of <svg>/<math> ancestors (0 again inside <foreignObject>)
}

// parse_template parses the contents of a `.html` template file into a Tree
// with a single root element. Identifiers in the template (`{{ x }}`,
// `@click="m"`, …) are kept verbatim; later phases resolve them against the
// component struct.
pub fn parse_template(tmpl string) !ast.Tree {
	return parse(tmpl, false)
}

// parse_html parses static HTML, a template's compiled skeleton, the way a
// browser's HTML parser does: `{{` is text, every attribute is static, the
// whitespace is kept as written, names are lowercased, and character references
// in text and attribute values are decoded. The native mock DOM is built from it.
pub fn parse_html(src string) !ast.Tree {
	return parse(src, true)
}

fn parse(src string, html bool) !ast.Tree {
	// HTML decoding drops a UTF-8 BOM, and the input stream turns CRLF and a
	// lone CR into LF
	mut text := if src.starts_with('\xef\xbb\xbf') { src[3..] } else { src }
	if text.contains_u8(`\r`) {
		text = text.replace('\r\n', '\n').replace('\r', '\n')
	}
	mut p := Parser{
		src:  text
		html: html
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
	name := p.read_name()
	if name == '' {
		return error('expected a tag name at ${p.at(p.pos)}')
	}
	is_comp := !p.html && is_component_name(name)
	l := if is_comp { '' } else { lower(name) }
	foreign := p.foreign > 0 || l in ['svg', 'math']
	// the browser lowercases HTML tag names; a template keeps what was written
	tag := if p.html && !foreign { l } else { name }
	mut node := ast.Node{
		kind:    if is_comp { ast.NodeKind.component } else { ast.NodeKind.element }
		tag:     tag
		foreign: foreign
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
		if c == `/` && p.has('/>') {
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
		p.skip_ws()
		if p.pos < p.src.len && p.src[p.pos] == `=` {
			p.pos++
			p.skip_ws()
			aval = p.read_attr_value()!
		}

		// classify the attribute
		if p.html {
			// HTML lowercases attribute names, and keeps the first of two
			// attributes with the same name
			an := if foreign { aname } else { lower(aname) }
			if !node.attrs.any(it.name == an) {
				node.attrs << ast.Attr{
					name:  an
					value: decode_attr_entities(aval)
				}
			}
		} else if aname.starts_with('@') {
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
				if ev[0] == '' || aval.trim_space() == '' {
					return error('event ${aname} on <${tag}> needs a handler, e.g. ${aname}="method", at ${p.at(apos)}')
				}
				node.events << ast.Event{
					name:         ev[0]
					modifiers:    if ev.len > 1 { ev[1..] } else { []string{} }
					handler_expr: aval.trim_space()
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

	if node.self_closing || (!is_comp && l in void_elements) {
		return node
	}
	// HTML's content rules are for HTML elements; a component's children are
	// template content whatever the component is called
	html_rules := !is_comp && !foreign
	if html_rules && l == 'plaintext' {
		return error('<plaintext> at ${p.at(open)} is not supported: it turns the rest of the page into text')
	}
	keep := html_rules && l in newline_elements
	if keep {
		p.drop_leading_newline()
	}
	if html_rules && (l in raw_text_elements || l in rcdata_elements) {
		node.raw_text = l in raw_text_elements
		p.parse_text_body(mut node, open)!
		return node
	}
	saved := p.foreign
	if l in ['svg', 'math'] {
		p.foreign++
	} else if foreign && l == 'foreignobject' {
		p.foreign = 0 // its children are HTML again
	}
	if keep {
		p.preserve++
	}
	p.parse_children(mut node, open)!
	if keep {
		p.preserve--
	}
	p.foreign = saved
	return node
}

// drop_leading_newline skips the newline right after a <pre>/<textarea>/
// <listing> start tag, as HTML does — also one written as a character
// reference (`&#10;`).
fn (mut p Parser) drop_leading_newline() {
	if p.pos >= p.src.len {
		return
	}
	if p.src[p.pos] == `\n` {
		p.pos++
	} else if p.src[p.pos] == `&` {
		text, next := char_ref(p.src, p.pos, false)
		if text == '\n' {
			p.pos = next
		}
	}
}

// split_for splits an @for value `item in source` around the first `in` with
// whitespace on both sides; `item` must be a plain identifier, and the source
// expression is kept as written.
fn split_for(v string) ?(string, string) {
	t := v.trim_space()
	mut i := 0
	for i < t.len && !is_ws(t[i]) {
		i++
	}
	item := t[..i]
	for i < t.len && is_ws(t[i]) {
		i++
	}
	if !item.is_identifier() || !has_at(t, i, 'in') || i + 2 >= t.len || !is_ws(t[i + 2]) {
		return none
	}
	source := t[i + 2..].trim_space()
	if source == '' {
		return none
	}
	return item, source
}

fn (mut p Parser) parse_children(mut parent ast.Node, open int) ! {
	for {
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}> opened at ${p.at(open)}')
		}
		// text runs to the next tag
		if p.html {
			start := p.pos
			for p.pos < p.src.len && !(p.src[p.pos] == `<` && p.starts_markup()) {
				p.pos++
			}
			if p.pos > start {
				parent.children << ast.Node{
					kind: .text
					text: decode_entities(p.src[start..p.pos])
				}
			}
		} else {
			p.read_text(mut parent, -1)!
		}
		if p.pos >= p.src.len {
			return error('unclosed tag <${parent.tag}> opened at ${p.at(open)}')
		}
		// at '<'
		if p.has('<!--') {
			text := p.read_comment()
			parent.children << ast.Node{
				kind: .comment
				text: text
			}
			continue
		}
		if p.has('</') {
			cpos := p.pos
			p.pos += 2
			cname := p.read_name()
			p.skip_ws()
			if p.pos >= p.src.len || p.src[p.pos] != `>` {
				return error('unclosed closing tag for <${parent.tag}> at ${p.at(cpos)}')
			}
			p.pos++
			same := if parent.kind == .component {
				cname == parent.tag
			} else {
				lower(cname) == lower(parent.tag)
			}
			if !same {
				return error('mismatched closing tag </${cname}> at ${p.at(cpos)}, expected </${parent.tag}> (opened at ${p.at(open)})')
			}
			if p.preserve == 0 && !p.html {
				condense(mut parent.children)
			}
			return
		}
		child := p.parse_element()!
		parent.children << child
	}
}

// read_text reads template text from pos up to `to` (or, when `to` < 0, up to
// the next markup), adding literal text and `{{ expr }}` interpolation nodes to
// `parent`. `{{{{` and `}}}}` are literal braces (except in a raw-text body,
// code whose braces are kept as written); anything inside `{{ }}`, even a `<`,
// belongs to the expression.
fn (mut p Parser) read_text(mut parent ast.Node, to int) ! {
	limit := if to >= 0 { to } else { p.src.len }
	mut lit := strings.new_builder(32)
	mut seg := p.pos
	for p.pos < limit {
		if !parent.raw_text && (p.has('{{{{') || p.has('}}}}')) {
			lit.write_string(p.src[seg..p.pos])
			lit.write_string(p.src[p.pos..p.pos + 2])
			p.pos += 4
			seg = p.pos
			continue
		}
		if p.has('{{') {
			close := index_of(p.src, '}}', p.pos + 2)
			if close < 0 || close + 2 > limit {
				return error('unterminated {{ at ${p.at(p.pos)} (missing }})')
			}
			expr := p.src[p.pos + 2..close].trim_space()
			if expr == '' {
				return error('empty {{ }} at ${p.at(p.pos)}')
			}
			lit.write_string(p.src[seg..p.pos])
			if lit.len > 0 {
				parent.children << ast.Node{
					kind: .text
					text: lit.str()
				}
			}
			parent.children << ast.Node{
				kind: .interpolation
				expr: expr
			}
			p.pos = close + 2
			seg = p.pos
			continue
		}
		if to < 0 && p.src[p.pos] == `<` && p.starts_markup() {
			break
		}
		p.pos++
	}
	lit.write_string(p.src[seg..p.pos])
	if lit.len > 0 {
		parent.children << ast.Node{
			kind: .text
			text: lit.str()
		}
	}
}

// parse_text_body reads the body of a raw-text (<script>, <style>, …) or RCDATA
// (<textarea>, <title>) element up to its end tag: text, never markup. A
// template may interpolate in it; HTML mode decodes an RCDATA body's
// references and keeps a raw-text body as written.
fn (mut p Parser) parse_text_body(mut node ast.Node, open int) ! {
	end := p.find_end_tag(node.tag)
	if end < 0 {
		return error('unclosed tag <${node.tag}> opened at ${p.at(open)}')
	}
	if p.html {
		if end > p.pos {
			body := p.src[p.pos..end]
			node.children << ast.Node{
				kind: .text
				text: if node.raw_text { body } else { decode_entities(body) }
			}
		}
	} else {
		p.read_text(mut node, end)!
	}
	p.pos = end + 2 + node.tag.len
	p.skip_ws()
	if p.pos >= p.src.len || p.src[p.pos] != `>` {
		return error('unclosed closing tag for <${node.tag}> at ${p.at(end)}')
	}
	p.pos++
}

// find_end_tag finds the `</tag` (any case) that ends a raw-text or RCDATA
// body: one followed by whitespace, `/` or `>`.
fn (p &Parser) find_end_tag(tag string) int {
	mut i := p.pos
	for {
		i = index_of(p.src, '</', i)
		if i < 0 {
			return -1
		}
		j := i + 2 + tag.len
		if j <= p.src.len && lower(p.src[i + 2..j]) == lower(tag)
			&& (j == p.src.len || is_ws(p.src[j]) || p.src[j] == `/` || p.src[j] == `>`) {
			return i
		}
		i += 2
	}
	return -1
}

// condense applies Vue's "condense" whitespace rule to one element's children,
// in place: a whitespace-only text node is removed when it is the first or last
// child, or sits between two elements/comments and contains a newline;
// otherwise it becomes a single space. Other text has its whitespace runs
// collapsed to one space. So indentation between tags vanishes, while
// `a <b>x</b> c` keeps its spaces.
fn condense(mut children []ast.Node) {
	mut i := 0
	for i < children.len {
		if children[i].kind != .text {
			i++
			continue
		}
		if is_blank(children[i].text) {
			first := i == 0
			last := i == children.len - 1
			between_tags := !first && !last && is_tag_like(children[i - 1])
				&& is_tag_like(children[i + 1])
			if first || last || (between_tags && children[i].text.contains_u8(`\n`)) {
				children.delete(i)
				continue
			}
			children[i].text = ' '
		} else {
			children[i].text = collapse_ws(children[i].text)
		}
		i++
	}
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

// --- lexical helpers --------------------------------------------------------

// starts_markup reports whether the `<` at pos begins a tag, closing tag or
// comment (HTML: `<` followed by a letter, `/` or `!`); otherwise it is text.
fn (p &Parser) starts_markup() bool {
	if p.pos + 1 >= p.src.len {
		return false
	}
	n := p.src[p.pos + 1]
	return n.is_letter() || n == `/` || n == `!`
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
		} else if p.has('<!--') {
			p.read_comment()
		} else {
			break
		}
	}
}

// read_comment consumes the comment at pos (`<!--`) and returns its text. Like
// HTML, `<!-->` and `<!--->` are empty comments, `--!>` ends one as `-->` does,
// and one with no end runs to the end.
fn (mut p Parser) read_comment() string {
	body := p.pos + 4
	for abrupt in ['>', '->'] {
		if has_at(p.src, body, abrupt) {
			p.pos = body + abrupt.len
			return ''
		}
	}
	for i := body; i < p.src.len; i++ {
		for close in ['-->', '--!>'] {
			if has_at(p.src, i, close) {
				p.pos = i + close.len
				return p.src[body..i]
			}
		}
	}
	p.pos = p.src.len
	return p.src[body..]
}

fn (mut p Parser) read_name() string {
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c.is_alnum() || c == `-` || c == `_` {
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
		if is_ws(c) || c == `>` || (c == `/` && p.has('/>')) {
			break
		}
		p.pos++
	}
	return p.src[start..p.pos]
}

// has reports whether the source continues with `s` at pos (without copying).
fn (p &Parser) has(s string) bool {
	return has_at(p.src, p.pos, s)
}

fn has_at(s string, i int, sub string) bool {
	if i < 0 || i + sub.len > s.len {
		return false
	}
	for k in 0 .. sub.len {
		if s[i + k] != sub[k] {
			return false
		}
	}
	return true
}

fn index_of(s string, sub string, from int) int {
	for i := from; i + sub.len <= s.len; i++ {
		if has_at(s, i, sub) {
			return i
		}
	}
	return -1
}

// lower is `s.to_lower()` without the copy when `s` has no capitals.
fn lower(s string) string {
	for c in s {
		if c >= `A` && c <= `Z` {
			return s.to_lower()
		}
	}
	return s
}

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

// is_component_name: a tag that starts with a capital names a component, except
// an HTML element name written in capitals (`<BR>`, `<TD>`), which is HTML.
fn is_component_name(tag string) bool {
	if tag.len == 0 || tag[0] < `A` || tag[0] > `Z` {
		return false
	}
	return !(tag.to_upper() == tag && tag.to_lower() in html_elements)
}
