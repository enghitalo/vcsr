// Phase 05 — Scoped CSS: parse a component's `.css` file, then scope, atomize,
// and tree-shake. Each component's stylesheet is (1) SCOPED so its class
// selectors carry a component-unique hash and can't collide across components,
// (2) ATOMIZED so identical declarations are emitted once and shared app-wide,
// and (3) TREE-SHAKEN so rules whose classes no template references are dropped.
//
// Plain V. A minimal but correct CSS tokenizer: selectors, declaration blocks,
// `@media` nesting, and `:root` custom-property pass-through. No `$`-builtins.
//
// See ../docs/ARCHITECTURE.md — styles live in `name.css`, parsed by vcsr.
module css

import strings

// --- public IR --------------------------------------------------------------

// ScopedCss is one component's stylesheet after its class selectors have been
// scoped to that component. `css` is the rewritten source; `renames` maps each
// original class selector (`.box`) to its scoped form (`.box_1a2b3c`).
pub struct ScopedCss {
pub:
	css     string
	renames map[string]string
}

// Sheet is the single app-wide stylesheet produced by `atomize`.
pub struct Sheet {
pub:
	text     string
	filename string // always ends with `.css`
}

// --- a tiny CSS model -------------------------------------------------------

// Decl is one `property: value` pair inside a rule.
struct Decl {
	prop  string
	value string
}

// Rule is one selector with its declaration block. `media` carries the enclosing
// `@media (…)` condition when the rule is nested, otherwise empty.
struct Rule {
	selector string
	decls    []Decl
	media    string
}

// --- scope ------------------------------------------------------------------

// scope rewrites every class selector in `css_src` to a component-unique form
// (`.box` → `.box_<hash>`), keyed to `component_name` so two components' `.box`
// never collide. `:root` blocks and custom properties pass through UNSCOPED, and
// `@media` blocks are preserved with their inner rules scoped intact.
pub fn scope(component_name string, css_src string) !ScopedCss {
	suffix := '_' + scope_token(component_name)
	rules := parse(css_src)!
	mut renames := map[string]string{}
	mut b := strings.new_builder(css_src.len + 32)
	mut cur_media := ''

	for ri, r in rules {
		if r.media != cur_media {
			if cur_media != '' {
				b.write_string('}\n')
			}
			if r.media != '' {
				b.write_string('${r.media} {\n')
			}
			cur_media = r.media
		}
		indent := if cur_media != '' { '\t' } else { '' }
		sel := scope_selector(r.selector, suffix, mut renames)
		b.write_string('${indent}${sel} {')
		for d in r.decls {
			b.write_string(' ${d.prop}: ${d.value};')
		}
		b.write_string(' }')
		if ri < rules.len - 1 || cur_media != '' {
			b.write_string('\n')
		}
	}
	if cur_media != '' {
		b.write_string('}\n')
	}

	return ScopedCss{
		css:     b.str()
		renames: renames.clone()
	}
}

// rename returns the scoped form of a class selector (`.box` → `.box_<hash>`),
// or an error if the selector was never seen in this component's stylesheet.
pub fn (s ScopedCss) rename(selector string) !string {
	if scoped := s.renames[selector] {
		return scoped
	}
	return error('selector "${selector}" not found in scoped stylesheet')
}

// scope_selector appends `suffix` to each class name in a (possibly compound)
// selector, leaving element/`:root`/pseudo parts untouched, and records the
// per-class rename. A `:root` selector is never scoped.
fn scope_selector(selector string, suffix string, mut renames map[string]string) string {
	if selector.trim_space() == ':root' {
		return selector
	}
	mut out := ''
	mut i := 0
	for i < selector.len {
		ch := selector[i]
		if ch == `.` && i + 1 < selector.len && is_ident_start(selector[i + 1]) {
			start := i
			i++ // consume `.`
			cstart := i
			for i < selector.len && (is_ident_part(selector[i]) || selector[i] == `-`) {
				i++
			}
			class := selector[cstart..i]
			renames['.${class}'] = '.${class}${suffix}'
			out += selector[start..i] + suffix
			continue
		}
		out += selector[i..i + 1]
		i++
	}
	return out
}

// --- atomize ----------------------------------------------------------------

// atomize merges every scoped sheet into ONE stylesheet, emitting each distinct
// declaration once (whitespace-normalized) so identical rules are shared.
pub fn atomize(sheets []ScopedCss) !Sheet {
	return atomize_with_usage(sheets, used_classes: [])!
}

@[params]
pub struct UsageOpt {
pub:
	used_classes []string // bare class names a template references; [] = keep all
}

// atomize_with_usage is `atomize` plus tree-shaking. It emits ATOMIC rules: each
// distinct declaration (whitespace-normalized) is emitted exactly once, shared by
// every selector that needs it — so two components' identical `padding:.5rem 1rem`
// becomes a single rule. When `used_classes` is non-empty, a class rule whose
// classes are all unreferenced is dropped; `:root`/element rules always stay.
pub fn atomize_with_usage(sheets []ScopedCss, opt UsageOpt) !Sheet {
	shake := opt.used_classes.len > 0
	mut order := []string{} // distinct `media\x00decl` keys, in first-seen order
	mut selectors := map[string][]string{} // key → selectors sharing that decl

	for sc in sheets {
		rules := parse(sc.css)!
		for r in rules {
			if shake && !rule_is_used(r.selector, opt.used_classes) {
				continue
			}
			for d in r.decls {
				decl := if d.prop == '__raw' {
					d.value
				} else {
					'${d.prop}:${collapse_ws(d.value)}'
				}
				key := '${r.media}\x00${decl}'
				if key !in selectors {
					order << key
				}
				if r.selector !in selectors[key] {
					selectors[key] << r.selector
				}
			}
		}
	}

	mut b := strings.new_builder(256)
	mut cur_media := ''
	for key in order {
		parts := key.split('\x00')
		media := parts[0]
		decl := parts[1]
		if media != cur_media {
			if cur_media != '' {
				b.write_string('}')
			}
			if media != '' {
				b.write_string('${media}{')
			}
			cur_media = media
		}
		b.write_string('${selectors[key].join(',')}{${decl}}')
	}
	if cur_media != '' {
		b.write_string('}')
	}

	return Sheet{
		text:     b.str()
		filename: 'app.css'
	}
}

// rule_is_used reports whether a selector references at least one used class. A
// selector with no class (element/`:root`) is always considered used.
fn rule_is_used(selector string, used []string) bool {
	classes := selector_classes(selector)
	if classes.len == 0 {
		return true
	}
	for c in classes {
		bare := strip_suffix_hash(c)
		if c in used || bare in used {
			return true
		}
	}
	return false
}

// selector_classes returns the class names (without leading `.`) in a selector.
fn selector_classes(selector string) []string {
	mut out := []string{}
	mut i := 0
	for i < selector.len {
		if selector[i] == `.` && i + 1 < selector.len && is_ident_start(selector[i + 1]) {
			i++
			start := i
			for i < selector.len && (is_ident_part(selector[i]) || selector[i] == `-`) {
				i++
			}
			out << selector[start..i]
			continue
		}
		i++
	}
	return out
}

// strip_suffix_hash drops a trailing `_<hex>` scope suffix, so a scoped class
// (`used_1a2b3c`) matches a bare template reference (`used`).
fn strip_suffix_hash(class string) string {
	idx := class.last_index_u8(`_`)
	if idx <= 0 {
		return class
	}
	tail := class[idx + 1..]
	if tail.len == 0 {
		return class
	}
	for ch in tail {
		if !is_hex(ch) {
			return class
		}
	}
	return class[..idx]
}

// normalize_decls renders a declaration block with canonical whitespace:
// `prop:value` with single-space-collapsed values, joined by `;`.
fn normalize_decls(decls []Decl) string {
	mut parts := []string{cap: decls.len}
	for d in decls {
		parts << '${d.prop}:${collapse_ws(d.value)}'
	}
	return parts.join(';')
}

// collapse_ws trims and collapses internal whitespace runs to single spaces.
fn collapse_ws(s string) string {
	mut b := strings.new_builder(s.len)
	mut in_ws := false
	for ch in s.trim_space() {
		if is_space(ch) {
			in_ws = true
			continue
		}
		if in_ws {
			b.write_u8(` `)
			in_ws = false
		}
		b.write_u8(ch)
	}
	return b.str()
}

// --- the tokenizer / parser -------------------------------------------------

// parse turns CSS source into a flat list of Rules, threading the enclosing
// `@media` condition through nested blocks. It understands selectors, brace
// blocks, declarations, and one level of `@media` nesting.
fn parse(src string) ![]Rule {
	mut rules := []Rule{}
	parse_block(src, '', mut rules)!
	return rules
}

// parse_block scans top-level rules in `src`, attributing each to `media`.
fn parse_block(src string, media string, mut rules []Rule) ! {
	mut i := 0
	for i < src.len {
		// skip whitespace
		if is_space(src[i]) {
			i++
			continue
		}
		// read up to the next `{` — that span is the selector or at-rule prelude
		start := i
		for i < src.len && src[i] != `{` && src[i] != `}` {
			i++
		}
		if i >= src.len {
			break
		}
		if src[i] == `}` {
			// stray close brace (end of an enclosing block) — stop
			return
		}
		prelude := src[start..i].trim_space()
		// consume the `{` and find its matching `}`
		body_start := i + 1
		mut depth := 1
		mut j := body_start
		for j < src.len && depth > 0 {
			if src[j] == `{` {
				depth++
			} else if src[j] == `}` {
				depth--
				if depth == 0 {
					break
				}
			}
			j++
		}
		body := src[body_start..j]
		i = j + 1

		if prelude.starts_with('@media') {
			parse_block(body, prelude, mut rules)!
		} else if prelude.starts_with('@') {
			// other at-rules (e.g. @keyframes): keep verbatim as a single rule
			rules << Rule{
				selector: prelude
				decls:    [
					Decl{
						prop:  '__raw'
						value: body.trim_space()
					},
				]
				media:    media
			}
		} else {
			rules << Rule{
				selector: prelude
				decls:    parse_decls(body)
				media:    media
			}
		}
	}
}

// parse_decls splits a declaration block into `prop: value` pairs.
fn parse_decls(body string) []Decl {
	mut out := []Decl{}
	for raw in body.split(';') {
		seg := raw.trim_space()
		if seg == '' {
			continue
		}
		ci := seg.index_u8(`:`)
		if ci < 0 {
			continue
		}
		prop := seg[..ci].trim_space()
		value := seg[ci + 1..].trim_space()
		if prop == '' {
			continue
		}
		out << Decl{
			prop:  prop
			value: value
		}
	}
	return out
}

// --- helpers ----------------------------------------------------------------

// scope_token derives a short, deterministic, name-unique suffix (FNV-1a hex).
fn scope_token(name string) string {
	mut h := u32(2166136261)
	for ch in name {
		h = (h ^ u32(ch)) * u32(16777619)
	}
	return h.hex()
}

fn is_space(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn is_ident_part(c u8) bool {
	return is_ident_start(c) || (c >= `0` && c <= `9`)
}

fn is_hex(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}
