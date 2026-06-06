// Phase 01 — Template parser: a `.html` template file → AST.
//
// vcsr parses a component's separate `.html` file (NOT an inline string, NOT a
// V compiler builtin) into a typed AST. Identifiers resolve in the component's
// scope, so the dialect is: `{{ expr }}` interpolation, `@event="handler"`,
// `@bind="signal"`, `class:name`, and the `@if`/`@for` directives.
//
// IMPLEMENTED. Run from the repo with the module on the path, e.g.:
//   ln -s "$PWD" ~/.vmodules/vcsr && v test tests/phase_01_template_parser_test.v
// See ../docs/ARCHITECTURE.md for why templates live in their own files.
module main

import vcsr.parser
import vcsr.ast { NodeKind }

// `parse_template` takes the CONTENTS of a `.html` file.
fn parse(html string) ast.Tree {
	return parser.parse_template(html) or { panic(err) }
}

// --- elements & text --------------------------------------------------------

fn test_parses_single_element() {
	tree := parse('<div></div>')
	assert tree.root.kind == NodeKind.element
	assert tree.root.tag == 'div'
	assert tree.root.children.len == 0
}

fn test_parses_static_text() {
	tree := parse('<p>hello</p>')
	assert tree.root.children[0].kind == NodeKind.text
	assert tree.root.children[0].text == 'hello'
}

fn test_parses_nested_tree() {
	html := '<section class="counter"><h1>{{ count }}</h1><button @click="inc">+1</button></section>'
	tree := parse(html)
	assert tree.root.tag == 'section'
	assert tree.root.children.len == 2
	assert tree.root.children[0].tag == 'h1'
	assert tree.root.children[1].tag == 'button'
}

fn test_parses_deeply_nested_tree() {
	tree := parse('<a><b><c></c></b></a>')
	assert tree.root.tag == 'a'
	assert tree.root.children[0].tag == 'b'
	assert tree.root.children[0].children[0].tag == 'c'
}

fn test_self_closing_tag() {
	tree := parse('<br/>')
	assert tree.root.tag == 'br'
	assert tree.root.self_closing
	assert tree.root.children.len == 0
}

fn test_self_closing_tag_with_space() {
	tree := parse('<input @bind="draft" />')
	assert tree.root.tag == 'input'
	assert tree.root.self_closing
}

fn test_skips_leading_comment() {
	tree := parse('<!-- a header comment -->\n<div></div>')
	assert tree.root.tag == 'div'
}

fn test_skips_child_comment() {
	tree := parse('<div><!-- note --><span>x</span></div>')
	assert tree.root.children.len == 1
	assert tree.root.children[0].tag == 'span'
}

// --- interpolation ----------------------------------------------------------

fn test_parses_interpolation() {
	tree := parse('<h1>{{ count }}</h1>')
	node := tree.root.children[0]
	assert node.kind == NodeKind.interpolation
	assert node.expr == 'count'
}

fn test_interpolation_allows_expressions() {
	tree := parse('<p>{{ a + b * 2 }}</p>')
	assert tree.root.children[0].expr == 'a + b * 2'
}

fn test_mixed_text_and_interpolation_order() {
	tree := parse('<p>double: {{ x }}!</p>')
	c := tree.root.children
	assert c.len == 3
	assert c[0].kind == NodeKind.text && c[0].text == 'double: '
	assert c[1].kind == NodeKind.interpolation && c[1].expr == 'x'
	assert c[2].kind == NodeKind.text && c[2].text == '!'
}

fn test_adjacent_interpolations() {
	tree := parse('<p>{{ a }}{{ b }}</p>')
	c := tree.root.children
	assert c.len == 2
	assert c[0].expr == 'a' && c[1].expr == 'b'
}

fn test_literal_braces_are_escaped() {
	tree := parse('<code>{{{{ not interpolation }}}}</code>')
	assert tree.root.children[0].kind == NodeKind.text
	assert tree.root.children[0].text.contains('{{')
}

fn test_preserves_utf8_text() {
	tree := parse('<p>Nothing here yet 🎉</p>')
	assert tree.root.children[0].text == 'Nothing here yet 🎉'
}

// --- attributes -------------------------------------------------------------

fn test_parses_static_attributes() {
	tree := parse('<section class="counter" id="c"></section>')
	assert tree.root.attr('class') or { panic(err) } == 'counter'
	assert tree.root.attr('id') or { panic(err) } == 'c'
}

fn test_attribute_value_may_contain_spaces() {
	tree := parse('<div data-x="a b c"></div>')
	assert tree.root.attr('data-x') or { panic(err) } == 'a b c'
}

fn test_single_quoted_attributes() {
	tree := parse("<div class='x'></div>")
	assert tree.root.attr('class') or { panic(err) } == 'x'
}

fn test_missing_attribute_errors() {
	tree := parse('<div></div>')
	tree.root.attr('nope') or {
		assert err.msg().contains('nope')
		return
	}
	assert false, 'expected an error for a missing attribute'
}

// --- events & directives ----------------------------------------------------

fn test_parses_event_handler() {
	tree := parse('<button @click="inc">+1</button>')
	ev := tree.root.events[0]
	assert ev.name == 'click'
	assert ev.handler_expr == 'inc'
}

fn test_parses_multiple_events() {
	tree := parse('<button @click="a" @mouseenter="b"></button>')
	assert tree.root.events.len == 2
	assert tree.root.events[0].name == 'click'
	assert tree.root.events[1].name == 'mouseenter'
}

fn test_event_handler_can_be_an_expression() {
	tree := parse('<button @click="remove(item.id)">x</button>')
	assert tree.root.events[0].handler_expr == 'remove(item.id)'
}

fn test_parses_event_modifiers() {
	tree := parse('<form @submit.prevent="save"></form>')
	ev := tree.root.events[0]
	assert ev.name == 'submit'
	assert ev.modifiers == ['prevent']
}

fn test_parses_two_way_bind() {
	tree := parse('<input @bind="draft" />')
	b := tree.root.binding or { panic('expected a @bind') }
	assert b.target_expr == 'draft'
}

fn test_parses_if_directive() {
	tree := parse('<button @if="count > 0">reset</button>')
	cond := tree.root.cond or { panic('expected an @if') }
	assert cond.expr == 'count > 0'
}

fn test_parses_for_directive_with_key() {
	tree := parse('<li @for="item in items" :key="item.id">{{ item.text }}</li>')
	each := tree.root.each or { panic('expected an @for') }
	assert each.item_name == 'item'
	assert each.source_expr == 'items'
	assert each.key_expr == 'item.id'
}

fn test_for_without_key() {
	tree := parse('<li @for="x in xs">{{ x }}</li>')
	each := tree.root.each or { panic('expected an @for') }
	assert each.item_name == 'x'
	assert each.source_expr == 'xs'
	assert each.key_expr == ''
}

fn test_malformed_for_errors() {
	parser.parse_template('<li @for="garbage">x</li>') or {
		assert err.msg().contains('@for')
		return
	}
	assert false, 'expected a malformed @for error'
}

fn test_parses_dynamic_class() {
	tree := parse('<li class:done="item.done">x</li>')
	cb := tree.root.class_bindings[0]
	assert cb.name == 'done'
	assert cb.expr == 'item.done'
}

// --- child components -------------------------------------------------------

fn test_parses_child_component_with_props() {
	tree := parse('<Button :label="name" kind="ghost" @click="inc" />')
	c := tree.root
	assert c.kind == NodeKind.component
	assert c.tag == 'Button'
	lbl := c.prop('label') or { panic('expected label') }
	assert lbl.bound && lbl.expr == 'name'
	knd := c.prop('kind') or { panic('expected kind') }
	assert !knd.bound && knd.value == 'ghost'
	assert c.events[0].name == 'click' && c.events[0].handler_expr == 'inc'
}

fn test_component_inside_element() {
	tree := parse('<main><Button label="+1" @click="inc" /></main>')
	assert tree.root.tag == 'main'
	child := tree.root.children[0]
	assert child.kind == NodeKind.component
	assert child.tag == 'Button'
}

// --- errors -----------------------------------------------------------------

fn test_rejects_unclosed_tag() {
	parser.parse_template('<div>') or {
		assert err.msg().contains('unclosed')
		return
	}
	assert false, 'expected an error for an unclosed tag'
}

fn test_rejects_mismatched_close() {
	parser.parse_template('<div></span>') or {
		assert err.msg().contains('mismatched')
		return
	}
	assert false, 'expected an error for a mismatched closing tag'
}

fn test_rejects_empty_template() {
	parser.parse_template('   ') or {
		assert err.msg().contains('empty')
		return
	}
	assert false, 'expected an error for an empty template'
}
