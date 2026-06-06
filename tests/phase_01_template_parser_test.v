// Phase 01 — Template parser: a `.html` template file → AST.
//
// GOAL: vcsr parses a component's separate `.html` file (NOT an inline string,
// NOT a V compiler builtin) into a typed AST. Identifiers resolve in the
// component's scope, so the dialect is: `{{ expr }}` interpolation,
// `@event="handler"`, `@bind="signal"`, and the `@if`/`@for` directives.
//
// SPEC-FIRST: describes the target behavior; the compiler is not implemented
// yet. See ../docs/ARCHITECTURE.md for why templates live in their own files.
module main

import vcsr.parser
import vcsr.ast { NodeKind }

// `parse_template` takes the CONTENTS of a `.html` file (vcsr reads the file;
// the parser works on the string).
fn test_parses_single_element() {
	tree := parser.parse_template('<div></div>')!
	assert tree.root.kind == NodeKind.element
	assert tree.root.tag == 'div'
	assert tree.root.children.len == 0
}

fn test_parses_static_text() {
	tree := parser.parse_template('<p>hello</p>')!
	assert tree.root.children[0].kind == NodeKind.text
	assert tree.root.children[0].text == 'hello'
}

fn test_parses_interpolation() {
	// {{ count }} resolves against the component struct (component scope)
	tree := parser.parse_template('<h1>{{ count }}</h1>')!
	node := tree.root.children[0]
	assert node.kind == NodeKind.interpolation
	assert node.expr == 'count'
}

fn test_interpolation_allows_expressions() {
	tree := parser.parse_template('<p>{{ a + b * 2 }}</p>')!
	assert tree.root.children[0].expr == 'a + b * 2'
}

fn test_literal_braces_are_escaped() {
	// `{{{{` escapes to a literal `{{` in text, so CSS/JS-ish content is safe
	tree := parser.parse_template('<code>{{{{ not interpolation }}}}</code>')!
	assert tree.root.children[0].kind == NodeKind.text
	assert tree.root.children[0].text.contains('{{')
}

fn test_parses_static_attributes() {
	tree := parser.parse_template('<section class="counter" id="c"></section>')!
	assert tree.root.attr('class')! == 'counter'
	assert tree.root.attr('id')! == 'c'
}

fn test_parses_event_handler() {
	// @click names a method on the component struct
	tree := parser.parse_template('<button @click="inc">+1</button>')!
	ev := tree.root.events[0]
	assert ev.name == 'click'
	assert ev.handler_expr == 'inc'
}

fn test_parses_event_modifiers() {
	tree := parser.parse_template('<form @submit.prevent="save"></form>')!
	ev := tree.root.events[0]
	assert ev.name == 'submit'
	assert ev.modifiers == ['prevent']
}

fn test_parses_two_way_bind() {
	tree := parser.parse_template('<input @bind="draft" />')!
	assert tree.root.binding!.target_expr == 'draft'
}

fn test_parses_if_directive() {
	tree := parser.parse_template('<button @if="count > 0">reset</button>')!
	assert tree.root.cond!.expr == 'count > 0'
}

fn test_parses_for_directive_with_key() {
	tree := parser.parse_template('<li @for="item in items" :key="item.id">{{ item.text }}</li>')!
	loop := tree.root.each!
	assert loop.item_name == 'item'
	assert loop.source_expr == 'items'
	assert loop.key_expr == 'item.id'
}

fn test_parses_dynamic_class() {
	tree := parser.parse_template('<li class:done="item.done">x</li>')!
	cls := tree.root.class_bindings[0]
	assert cls.name == 'done'
	assert cls.expr == 'item.done'
}

fn test_parses_child_component_with_props() {
	// PascalCase tag => child component; `:label` is a bound prop, `kind` static
	tree := parser.parse_template('<Button :label="name" kind="ghost" @click="inc" />')!
	c := tree.root
	assert c.kind == NodeKind.component
	assert c.tag == 'Button'
	assert c.prop('label')!.bound && c.prop('label')!.expr == 'name'
	assert !c.prop('kind')!.bound && c.prop('kind')!.value == 'ghost'
	assert c.events[0].name == 'click' && c.events[0].handler_expr == 'inc'
}

fn test_parses_nested_tree() {
	html := '<section class="counter"><h1>{{ count }}</h1><button @click="inc">+1</button></section>'
	tree := parser.parse_template(html)!
	assert tree.root.tag == 'section'
	assert tree.root.children.len == 2
	assert tree.root.children[0].tag == 'h1'
	assert tree.root.children[1].tag == 'button'
}

fn test_self_closing_tag() {
	tree := parser.parse_template('<br/>')!
	assert tree.root.tag == 'br'
	assert tree.root.self_closing
}

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
	assert false, 'expected an error for mismatched closing tag'
}
