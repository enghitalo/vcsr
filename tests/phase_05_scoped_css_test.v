// Phase 05 — component styles: css.scope (attribute scoping, a tokenizer that
// copies declarations verbatim, at-rules, nesting, errors with line:col) and
// css.bundle (one app sheet, deduped without reordering the cascade).
module main

import vcsr.css

const a = css.scope_attr('Card')

fn sc(src string) string {
	return css.scope('Card', src) or { panic(err) }.css
}

fn test_scopes_last_compound_before_pseudos() {
	assert a.starts_with('data-s-') && a.len == 'data-s-'.len + 8
	assert sc('.title { color: red }') == '.title[${a}]{color: red}'
	assert sc('.card .title:hover::after { x: 1 }') == '.card .title[${a}]:hover::after{x: 1}'
	assert sc('ul > li + li ~ p { x: 1 }') == 'ul > li + li ~ p[${a}]{x: 1}'
	assert sc('p, .a,  .b>i { x: 1 }') == 'p[${a}],.a[${a}],.b>i[${a}]{x: 1}'
	assert sc('a:not(.x, .y) { x: 1 }') == 'a[${a}]:not(.x, .y){x: 1}'
}

fn test_globals_stay_global() {
	assert sc(':root { --fg: #000 }') == ':root{--fg: #000}'
	assert sc('html, body:hover { x: 1 }') == 'html,body:hover{x: 1}'
	assert sc(':global(.toast) { x: 1 }') == '.toast{x: 1}'
	assert sc('.dark :global(.x) { x: 1 }') == '.dark .x{x: 1}'
	assert sc('.dark .card { x: 1 }') == '.dark .card[${a}]{x: 1}' // ancestor theming
}

fn test_attribute_selectors_and_escapes_are_not_mangled() {
	assert sc('a[href$=".pdf"] { x: 1 }') == 'a[href$=".pdf"][${a}]{x: 1}'
	assert sc('.sm\\:p-2 { x: 1 }') == '.sm\\:p-2[${a}]{x: 1}'
}

fn test_declarations_are_verbatim_strings_urls_comments() {
	assert sc('.i { background: url("data:image/svg+xml;utf8,<svg>{}</svg>"); content: "a;b}" }') == '.i[${a}]{background: url("data:image/svg+xml;utf8,<svg>{}</svg>"); content: "a;b}"}'
	assert sc('/* { } .not-a-rule */ .x { /* old: blue; */ color: red; }') == '.x[${a}]{color: red;}'
	assert sc('.u { background: url(a;b.png) }') == '.u[${a}]{background: url(a;b.png)}'
}

fn test_at_rules() {
	assert sc('@media (min-width: 40rem) { .grid { display: grid } }') == '@media (min-width: 40rem){.grid[${a}]{display: grid}}'
	assert sc('@media screen { @supports (display: grid) { .g { x: 1 } } }') == '@media screen{@supports (display: grid){.g[${a}]{x: 1}}}'
	assert sc('@keyframes spin { from { transform: rotate(0) } to { transform: rotate(1turn) } }') == '@keyframes spin{from { transform: rotate(0) } to { transform: rotate(1turn) }}'
	assert sc('@font-face { font-family: X; src: url(x.woff2) }') == '@font-face{font-family: X; src: url(x.woff2)}'
	assert sc('@import url("x.css"); .a { x: 1 }') == '@import url("x.css");.a[${a}]{x: 1}'
	assert sc('@layer base, ui; @layer ui { .b { x: 1 } }') == '@layer base, ui;@layer ui{.b[${a}]{x: 1}}'
}

fn test_css_nesting() {
	assert sc('.card { padding: 1rem; &:hover { x: 1 } .title { y: 2 } }') == '.card[${a}]{padding: 1rem;&[${a}]:hover{x: 1}.title[${a}]{y: 2}}'
}

fn test_tree_shaking_by_used_classes() {
	out := css.scope('Card',
		'.used { a: 1 } .dead { b: 2 } .dark .used { c: 3 } p { d: 4 } .used.dead { e: 5 }',
		used_classes: ['used']
	)!.css
	assert out == '.used[${a}]{a: 1}.dark .used[${a}]{c: 3}p[${a}]{d: 4}'
}

fn test_bundle_dedupes_cascade_safely() {
	x := css.scope('A', '.a { color: red } .b { color: blue } .a { color: red }')!
	sheet := css.bundle([x])
	ax := css.scope_attr('A')
	// the EARLIER duplicate goes: `class="a b"` stays red, exactly as before
	assert sheet.text == '.b[${ax}]{color: blue}.a[${ax}]{color: red}'
	y := css.scope('B', '@media print { .p { x: 1 } } @media print { .q { y: 2 } }')!
	assert css.bundle([y]).text.contains('@media print{.p[') // contexts re-open correctly
	assert sheet.filename == 'app.css'
}

fn test_two_components_get_different_attrs() {
	assert css.scope_attr('A') != css.scope_attr('B')
}

fn expect_err(src string, want string) {
	css.scope('Card', src) or {
		assert err.msg().contains(want), err.msg()
		return
	}
	assert false, 'expected an error for ${src}'
}

fn test_malformed_css_is_an_error_with_location() {
	expect_err('.a { color: red', 'unclosed')
	expect_err('.a { x: 1 } }', 'line 1, col 13')
	expect_err('.a { content: "x }', 'unclosed')
	expect_err('/* never closed', 'unterminated comment')
	expect_err('.a\n.b', 'expected `{`')
}

fn test_global_unwraps_anywhere_in_a_selector() {
	// a leftover `:global(` would make the whole rule invalid CSS
	assert sc(':global(.dark) .card { x: 1 }') == '.dark .card[${a}]{x: 1}'
	assert sc('@media (x) { :global(.y) .z, .w :global(.v) { x: 1 } }') == '@media (x){.y .z[${a}],.w .v{x: 1}}'
}
