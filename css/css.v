// Phase 05 — component styles: parse a component's `.css`, SCOPE it to the
// component, and BUNDLE every component's sheet into one app stylesheet.
//
// SCOPING is by attribute, the approach Vue's `<style scoped>` uses: every
// element of a component's skeleton carries `data-s-<hash>` (see scope_attr),
// and the LAST compound of every selector gets `[data-s-<hash>]`:
//   .card .title:hover   →  .card .title[data-s-1a2b3c4d]:hover
// Class names in the markup stay as written (so `:class`/`class:x` bindings
// need no rewriting), element selectors (`p {}`) are scoped too, and an
// ancestor outside the component can still theme it (`.dark .card`). `:root`,
// `html` and `body` stay global, as does anything wrapped in `:global(...)`.
//
// The tokenizer only rewrites SELECTORS: declaration blocks are copied
// verbatim, so values with `;`, braces or comments inside strings and `url()`
// survive by construction. Comments are dropped. `@media`, `@supports`,
// `@container`, `@layer` and `@scope` blocks are recursed into and their rules
// scoped; other block at-rules (`@keyframes`, `@font-face`, …) are copied
// verbatim; statement at-rules (`@import`, `@layer a, b;`) are kept as written.
// CSS nesting (`.card { &:hover {} .title {} }`) is supported: nested rules are
// scoped the same way.
module css

import strings

// ScopedCss is one component's stylesheet after scoping.
pub struct ScopedCss {
pub:
	component string
	attr      string // the scope attribute its elements carry, e.g. `data-s-1a2b3c4d`
	css       string // the scoped stylesheet
mut:
	nodes []CssNode // the scoped sheet, for bundling
}

// Sheet is the single app-wide stylesheet produced by bundle().
pub struct Sheet {
pub:
	text     string
	filename string // always ends with `.css`
}

enum NodeKind {
	rule     // `selector { declarations [nested rules] }`
	at_group // `@media …` / `@supports …` / … { rules }
	at_raw   // `@keyframes …` / `@font-face` { opaque body }
	at_stmt  // `@import …;` / `@layer a, b;`
}

struct CssNode {
mut:
	kind     NodeKind
	prelude  string    // selector list, or the at-rule prelude including `@name`
	body     string    // rule: its own declarations; at_raw: the opaque body
	children []CssNode // at_group: rules; rule: nested rules (CSS nesting)
}

// group_at_rules hold rules and are recursed into (their rules get scoped).
const group_at_rules = ['media', 'supports', 'container', 'layer', 'scope', 'document']

// scope_attr is the attribute a component's elements carry for its scoped styles.
pub fn scope_attr(component_name string) string {
	return 'data-s-' + scope_token(component_name)
}

@[params]
pub struct ScopeOpt {
pub:
	// used_classes: when set, a rule is dropped if its scoped compound names a
	// class the component's template never uses (it can't match any element).
	used_classes ?[]string
}

// scope parses `css_src` and scopes it to `component_name` (see the module doc).
// Malformed CSS (an unclosed `{` or string, a stray `}`) is an error with its
// line and column.
pub fn scope(component_name string, css_src string, opt ScopeOpt) !ScopedCss {
	attr := scope_attr(component_name)
	mut p := CssParser{
		src: css_src
	}
	parsed := p.parse_list(false)!
	nodes := scope_nodes(parsed, attr, opt.used_classes)
	return ScopedCss{
		component: component_name
		attr:      attr
		css:       render(nodes)
		nodes:     nodes
	}
}

fn scope_nodes(nodes []CssNode, attr string, used ?[]string) []CssNode {
	mut out := []CssNode{}
	for n in nodes {
		match n.kind {
			.rule {
				mut sels := []string{}
				for sel in split_top(n.prelude, `,`) {
					s := sel.trim_space()
					if s == '' {
						continue
					}
					if u := used {
						if !compound_can_match(last_compound(s), u) {
							continue
						}
					}
					sels << scope_selector(s, attr)
				}
				if sels.len == 0 {
					continue // every selector was tree-shaken
				}
				out << CssNode{
					kind:     .rule
					prelude:  sels.join(',')
					body:     n.body
					children: scope_nodes(n.children, attr, used)
				}
			}
			.at_group {
				children := scope_nodes(n.children, attr, used)
				if children.len > 0 {
					out << CssNode{
						kind:     .at_group
						prelude:  n.prelude
						children: children
					}
				}
			}
			else {
				out << n
			}
		}
	}
	return out
}

// scope_selector adds `[attr]` to the last compound of one complex selector,
// before any pseudo-class/element: `.a > .b:hover::after` → `.a > .b[attr]:hover::after`.
// `:global(x)` is unwrapped and left unscoped; `:root`/`html`/`body` stay global.
fn scope_selector(sel string, attr string) string {
	start := last_compound_start(sel)
	compound := sel[start..]
	head := unwrap_global(sel[..start])
	if compound.starts_with(':global(') || is_global_compound(compound) {
		return head + unwrap_global(compound)
	}
	ins := pseudo_start(compound)
	return head + compound[..ins] + '[${attr}]' + compound[ins..]
}

// unwrap_global replaces every `:global(x)` in a selector by `x`: the escape
// hatch is vcsr's, the browser must not see it.
fn unwrap_global(sel string) string {
	mut out := sel
	for {
		i := out.index(':global(') or { return out }
		end := skip_parens(out, i + 7)
		out = out[..i] + out[i + 8..end - 1] + out[end..]
	}
	return out
}

// last_compound returns the last compound of a complex selector.
fn last_compound(sel string) string {
	return sel[last_compound_start(sel)..]
}

// last_compound_start finds where the last compound selector begins: after the
// last top-level combinator (whitespace, `>`, `+`, `~`).
fn last_compound_start(sel string) int {
	mut depth := 0
	mut last := 0
	mut i := 0
	for i < sel.len {
		c := sel[i]
		if c == `\\` {
			i += 2 // an escaped character (`.sm\\:p-2`) is part of the name
			continue
		}
		if c == `"` || c == `'` {
			i = skip_string(sel, i)
			continue
		}
		if c == `(` || c == `[` {
			depth++
		} else if c == `)` || c == `]` {
			depth--
		} else if depth == 0 && (is_space(c) || c == `>` || c == `+` || c == `~`) {
			last = i + 1
		}
		i++
	}
	return last
}

// pseudo_start is the index in a compound where its pseudo-classes/elements
// begin (`.b:hover` → 2), or its length if it has none.
fn pseudo_start(compound string) int {
	mut depth := 0
	mut i := 0
	for i < compound.len {
		c := compound[i]
		if c == `\\` {
			i += 2
			continue
		}
		if c == `"` || c == `'` {
			i = skip_string(compound, i)
			continue
		}
		if c == `(` || c == `[` {
			depth++
		} else if c == `)` || c == `]` {
			depth--
		} else if c == `:` && depth == 0 {
			return i
		}
		i++
	}
	return compound.len
}

// is_global_compound: `:root…`, `html…`, `body…` belong to the document.
fn is_global_compound(compound string) bool {
	return compound.starts_with(':root') || compound_base(compound) in ['html', 'body']
}

// compound_base strips pseudos from a compound (`body:hover` → `body`).
fn compound_base(compound string) string {
	return compound[..pseudo_start(compound)]
}

// compound_can_match reports whether every class a compound names is in `used`
// (a compound with no class can match anything).
fn compound_can_match(compound string, used []string) bool {
	base := compound_base(compound)
	mut i := 0
	for i < base.len {
		if base[i] == `[` {
			i = skip_brackets(base, i)
			continue
		}
		if base[i] == `.` {
			i++
			start := i
			for i < base.len && (is_ident_part(base[i]) || base[i] == `-` || base[i] == `\\`) {
				i += if base[i] == `\\` { 2 } else { 1 }
			}
			if base[start..i] !in used {
				return false
			}
			continue
		}
		i++
	}
	return true
}

// --- bundling -----------------------------------------------------------------

// bundle merges every component's scoped sheet into one stylesheet, in order.
// An identical rule (same at-rule context, selectors and declarations) that
// appears again LATER is emitted only once — at its last position. Dropping
// the earlier copy is always cascade-safe: the later one, with equal
// specificity, overrides everything the earlier one could.
pub fn bundle(sheets []ScopedCss) Sheet {
	mut flat := []FlatRule{}
	for sc in sheets {
		flatten(sc.nodes, [], mut flat)
	}
	mut last := map[string]int{}
	for i, f in flat {
		last[f.key()] = i
	}
	mut kept := []FlatRule{}
	for i, f in flat {
		if last[f.key()] == i {
			kept << f
		}
	}
	return Sheet{
		text:     render_flat(kept)
		filename: 'app.css'
	}
}

struct FlatRule {
	context []string // enclosing at-rule preludes, outermost first
	node    CssNode  // a rule, at_raw or at_stmt (with its nested children)
}

fn (f FlatRule) key() string {
	return f.context.join('\x01') + '\x00' + render([f.node])
}

fn flatten(nodes []CssNode, ctx []string, mut out []FlatRule) {
	for n in nodes {
		if n.kind == .at_group {
			mut c := ctx.clone()
			c << n.prelude
			flatten(n.children, c, mut out)
		} else {
			out << FlatRule{
				context: ctx
				node:    n
			}
		}
	}
}

// render_flat writes flat rules back out, re-opening at-rule groups as the
// context changes between consecutive rules.
fn render_flat(rules []FlatRule) string {
	mut b := strings.new_builder(256)
	mut open := []string{}
	for f in rules {
		mut common := 0
		for common < open.len && common < f.context.len && open[common] == f.context[common] {
			common++
		}
		for open.len > common {
			b.write_u8(`}`)
			open = open[..open.len - 1].clone()
		}
		for k in common .. f.context.len {
			b.write_string('${f.context[k]}{')
			open << f.context[k]
		}
		b.write_string(render([f.node]))
	}
	for _ in open {
		b.write_u8(`}`)
	}
	return b.str()
}

// render serializes nodes compactly.
fn render(nodes []CssNode) string {
	mut b := strings.new_builder(128)
	for n in nodes {
		match n.kind {
			.rule {
				b.write_string('${n.prelude}{${n.body}')
				if n.children.len > 0 {
					b.write_string(render(n.children))
				}
				b.write_u8(`}`)
			}
			.at_group {
				b.write_string('${n.prelude}{${render(n.children)}}')
			}
			.at_raw {
				b.write_string('${n.prelude}{${n.body}}')
			}
			.at_stmt {
				b.write_string('${n.prelude};')
			}
		}
	}
	return b.str()
}

// --- the tokenizer / parser ---------------------------------------------------

struct CssParser {
	src string
mut:
	pos int
}

// parse_list parses rules/at-rules until EOF (top level) or a `}` (nested).
fn (mut p CssParser) parse_list(nested bool) ![]CssNode {
	mut out := []CssNode{}
	for {
		p.skip_ws_comments()!
		if p.pos >= p.src.len {
			if nested {
				return error('unclosed `{` (missing `}`) at end of stylesheet')
			}
			return out
		}
		if p.src[p.pos] == `}` {
			if nested {
				return out
			}
			return error('unexpected `}` at ${p.at(p.pos)}')
		}
		start := p.pos
		prelude, term := p.read_prelude()!
		if term == `;` {
			if prelude.starts_with('@') {
				out << CssNode{
					kind:    .at_stmt
					prelude: prelude
				}
				continue
			}
			return error('expected `{` after selector "${prelude}" at ${p.at(start)}')
		}
		// term == `{`
		if prelude.starts_with('@') {
			name := at_name(prelude)
			if name in group_at_rules {
				children := p.parse_list(true)!
				p.pos++ // `}`
				out << CssNode{
					kind:     .at_group
					prelude:  prelude
					children: children
				}
			} else {
				body := p.read_block_raw(start)!
				out << CssNode{
					kind:    .at_raw
					prelude: prelude
					body:    body
				}
			}
			continue
		}
		decls, children := p.parse_rule_body(start)!
		out << CssNode{
			kind:     .rule
			prelude:  collapse_ws(prelude)
			body:     decls
			children: children
		}
	}
	return out
}

// read_prelude reads up to the next top-level `{` or `;`, skipping comments,
// strings and bracketed/parenthesized parts; returns it trimmed + the terminator.
fn (mut p CssParser) read_prelude() !(string, u8) {
	start := p.pos
	mut b := strings.new_builder(32)
	mut depth := 0
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == `/` && p.peek(1) == `*` {
			p.skip_comment()!
			b.write_u8(` `)
			continue
		}
		if c == `"` || c == `'` {
			end := skip_string(p.src, p.pos)
			if end > p.src.len || (end == p.src.len && p.src[p.src.len - 1] != c) {
				return error('unterminated string at ${p.at(p.pos)}')
			}
			b.write_string(p.src[p.pos..end])
			p.pos = end
			continue
		}
		if c == `(` || c == `[` {
			depth++
		} else if c == `)` || c == `]` {
			depth--
		} else if depth == 0 && (c == `{` || c == `;`) {
			p.pos++
			return b.str().trim_space(), c
		} else if depth == 0 && c == `}` {
			return error('unexpected `}` in selector at ${p.at(p.pos)}')
		}
		b.write_u8(c)
		p.pos++
	}
	return error('expected `{` after "${p.src[start..].trim_space()}" (unclosed rule at ${p.at(start)})')
}

// parse_rule_body splits a rule's block into its own declarations (verbatim,
// trimmed) and nested rules (CSS nesting). The cursor is just past `{`; on
// return it is just past the matching `}`.
fn (mut p CssParser) parse_rule_body(open int) !(string, []CssNode) {
	mut decls := strings.new_builder(64)
	mut children := []CssNode{}
	mut seg_start := p.pos
	for {
		if p.pos >= p.src.len {
			return error('unclosed `{` of the rule at ${p.at(open)}')
		}
		c := p.src[p.pos]
		if c == `/` && p.peek(1) == `*` {
			decls.write_string(p.src[seg_start..p.pos])
			p.skip_comment()!
			seg_start = p.pos
			continue
		}
		if c == `"` || c == `'` {
			p.pos = skip_string(p.src, p.pos)
			continue
		}
		if c == `(` {
			p.pos = skip_parens(p.src, p.pos)
			continue
		}
		if c == `}` {
			decls.write_string(p.src[seg_start..p.pos])
			p.pos++
			return trim_decls(decls.str()), children
		}
		if c == `{` {
			// a nested rule: its prelude is the text since the last `;` or block
			seg := p.src[seg_start..p.pos]
			cut := seg.last_index_u8(`;`)
			head := if cut >= 0 { seg[..cut + 1] } else { '' }
			decls.write_string(head)
			prelude := collapse_ws(strip_comments(seg[cut + 1..]))
			p.pos++
			nested_decls, nested_children := p.parse_rule_body(p.pos - 1)!
			children << CssNode{
				kind:     .rule
				prelude:  prelude
				body:     nested_decls
				children: nested_children
			}
			seg_start = p.pos
			continue
		}
		p.pos++
	}
	return '', children
}

// read_block_raw copies an opaque at-rule body (cursor just past `{`) up to its
// matching `}`, comments removed.
fn (mut p CssParser) read_block_raw(open int) !string {
	mut b := strings.new_builder(64)
	mut depth := 1
	mut seg := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == `/` && p.peek(1) == `*` {
			b.write_string(p.src[seg..p.pos])
			p.skip_comment()!
			seg = p.pos
			continue
		}
		if c == `"` || c == `'` {
			p.pos = skip_string(p.src, p.pos)
			continue
		}
		if c == `{` {
			depth++
		} else if c == `}` {
			depth--
			if depth == 0 {
				b.write_string(p.src[seg..p.pos])
				p.pos++
				return collapse_ws(b.str())
			}
		}
		p.pos++
	}
	return error('unclosed `{` of the at-rule at ${p.at(open)}')
}

fn (mut p CssParser) skip_ws_comments() ! {
	for p.pos < p.src.len {
		if is_space(p.src[p.pos]) {
			p.pos++
		} else if p.src[p.pos] == `/` && p.peek(1) == `*` {
			p.skip_comment()!
		} else {
			break
		}
	}
}

fn (mut p CssParser) skip_comment() ! {
	end := p.src.index_after('*/', p.pos + 2) or {
		return error('unterminated comment at ${p.at(p.pos)}')
	}
	p.pos = end + 2
}

fn (p &CssParser) peek(k int) u8 {
	return if p.pos + k < p.src.len { p.src[p.pos + k] } else { 0 }
}

fn (p &CssParser) at(pos int) string {
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

// --- helpers --------------------------------------------------------------------

// skip_string returns the index just past the string literal starting at `i`.
fn skip_string(s string, i int) int {
	q := s[i]
	mut j := i + 1
	for j < s.len && s[j] != q {
		if s[j] == `\\` {
			j++
		}
		j++
	}
	return if j < s.len { j + 1 } else { s.len }
}

// skip_parens returns the index just past the `(…)` group starting at `i`
// (strings inside are skipped, so `url("a)b")` is one group).
fn skip_parens(s string, i int) int {
	mut depth := 0
	mut j := i
	for j < s.len {
		c := s[j]
		if c == `"` || c == `'` {
			j = skip_string(s, j)
			continue
		}
		if c == `(` {
			depth++
		} else if c == `)` {
			depth--
			if depth == 0 {
				return j + 1
			}
		}
		j++
	}
	return s.len
}

fn skip_brackets(s string, i int) int {
	mut j := i
	for j < s.len && s[j] != `]` {
		if s[j] == `"` || s[j] == `'` {
			j = skip_string(s, j)
			continue
		}
		j++
	}
	return j + 1
}

// split_top splits on `sep` outside of parens, brackets and strings.
fn split_top(s string, sep u8) []string {
	mut out := []string{}
	mut depth := 0
	mut start := 0
	mut i := 0
	for i < s.len {
		c := s[i]
		if c == `"` || c == `'` {
			i = skip_string(s, i)
			continue
		}
		if c == `(` || c == `[` {
			depth++
		} else if c == `)` || c == `]` {
			depth--
		} else if c == sep && depth == 0 {
			out << s[start..i]
			start = i + 1
		}
		i++
	}
	out << s[start..]
	return out
}

fn at_name(prelude string) string {
	mut i := 1
	for i < prelude.len && (is_ident_part(prelude[i]) || prelude[i] == `-`) {
		i++
	}
	return prelude[1..i].to_lower()
}

fn strip_comments(s string) string {
	mut b := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == `/` && i + 1 < s.len && s[i + 1] == `*` {
			end := s.index_after('*/', i + 2) or { s.len - 2 }
			i = end + 2
			continue
		}
		b.write_u8(s[i])
		i++
	}
	return b.str()
}

// trim_decls trims a declaration block and collapses whitespace outside strings.
fn trim_decls(s string) string {
	return collapse_ws(s)
}

// collapse_ws trims and collapses whitespace runs to one space, leaving the
// insides of strings untouched.
fn collapse_ws(s string) string {
	mut b := strings.new_builder(s.len)
	mut in_ws := false
	mut i := 0
	t := s.trim_space()
	for i < t.len {
		c := t[i]
		if c == `"` || c == `'` {
			if in_ws {
				b.write_u8(` `)
				in_ws = false
			}
			end := skip_string(t, i)
			b.write_string(t[i..end])
			i = end
			continue
		}
		if is_space(c) {
			in_ws = true
			i++
			continue
		}
		if in_ws {
			b.write_u8(` `)
			in_ws = false
		}
		b.write_u8(c)
		i++
	}
	return b.str()
}

// scope_token derives a short, deterministic, name-unique suffix (FNV-1a hex).
fn scope_token(name string) string {
	mut h := u32(2166136261)
	for ch in name {
		h = (h ^ u32(ch)) * u32(16777619)
	}
	return h.hex_full()
}

fn is_space(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r` || c == `\f`
}

fn is_ident_part(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_` || (c >= `0` && c <= `9`)
}
