// Phase 01 — Template parser: markup → AST.
//
// GOAL: turn a `$vui('…')` markup string into a typed AST that later phases
// lower. The parser must recognize elements, text, `${expr}` interpolation,
// `@event` handlers, two-way `@bind`, and the `@if`/`@for` directives, and it
// must reject malformed markup with a useful error.
//
// SPEC-FIRST: these tests describe the target behavior; the compiler is not
// implemented yet. `v test` will not pass until phase 01 lands.
module main

import vcsr.parser
import vcsr.ast { NodeKind }

const counter_markup = '<section class="counter"><h1>${count}</h1><button @click=${inc}>+1</button></section>'

fn test_parses_single_element() {
	tree := parser.parse('<div></div>')!
	assert tree.root.kind == NodeKind.element
	assert tree.root.tag == 'div'
	assert tree.root.children.len == 0
}

fn test_parses_static_text() {
	tree := parser.parse('<p>hello</p>')!
	assert tree.root.children.len == 1
	assert tree.root.children[0].kind == NodeKind.text
	assert tree.root.children[0].text == 'hello'
}

fn test_parses_interpolation() {
	tree := parser.parse('<h1>${count}</h1>')!
	node := tree.root.children[0]
	assert node.kind == NodeKind.interpolation
	assert node.expr == 'count'
}

fn test_parses_static_attributes() {
	tree := parser.parse('<section class="counter" id="c"></section>')!
	assert tree.root.attr('class')! == 'counter'
	assert tree.root.attr('id')! == 'c'
}

fn test_parses_event_handler() {
	tree := parser.parse('<button @click=${inc}>+1</button>')!
	ev := tree.root.events[0]
	assert ev.name == 'click'
	assert ev.handler_expr == 'inc'
}

fn test_parses_event_modifiers() {
	tree := parser.parse('<form @submit.prevent=${save}></form>')!
	ev := tree.root.events[0]
	assert ev.name == 'submit'
	assert ev.modifiers == ['prevent']
}

fn test_parses_two_way_bind() {
	tree := parser.parse('<input @bind=${draft} />')!
	assert tree.root.binding!.target_expr == 'draft'
}

fn test_parses_if_directive() {
	tree := parser.parse('<button @if=${count > 0}>reset</button>')!
	assert tree.root.cond!.expr == 'count > 0'
}

fn test_parses_for_directive_with_key() {
	tree := parser.parse('<li @for=${item in items} :key=${item.id}>${item.text}</li>')!
	loop := tree.root.each!
	assert loop.item_name == 'item'
	assert loop.source_expr == 'items'
	assert loop.key_expr == 'item.id'
}

fn test_parses_nested_tree() {
	tree := parser.parse(counter_markup)!
	assert tree.root.tag == 'section'
	assert tree.root.children.len == 2
	assert tree.root.children[0].tag == 'h1'
	assert tree.root.children[1].tag == 'button'
}

fn test_self_closing_tag() {
	tree := parser.parse('<br/>')!
	assert tree.root.tag == 'br'
	assert tree.root.self_closing
}

fn test_rejects_unclosed_tag() {
	parser.parse('<div>') or {
		assert err.msg().contains('unclosed')
		return
	}
	assert false, 'expected an error for an unclosed tag'
}

fn test_rejects_mismatched_close() {
	parser.parse('<div></span>') or {
		assert err.msg().contains('mismatched')
		return
	}
	assert false, 'expected an error for mismatched closing tag'
}
