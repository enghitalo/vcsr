// Phase 05 — Scoped CSS: scope + atomize + tree-shake.
//
// GOAL: each component's `$css('…')` is (1) scoped so its selectors can't leak
// or collide across components, (2) atomized so identical declarations are
// shared app-wide, and (3) tree-shaken so rules whose classes no template
// references are dropped. The output is one stylesheet plus a class-rename map
// the templates use.
module main

import vcsr.css

fn test_scopes_class_selectors_with_hash() {
	out := css.scope('Counter', '.value { font-size: 3rem; }')!
	// the selector is rewritten to a component-unique class
	assert out.rename('.value')!.starts_with('.value_') || out.css.contains('value_')
	// the original bare `.value` no longer appears unscoped
	assert !out.css.contains(' .value ')
}

fn test_two_components_same_classname_dont_collide() {
	a := css.scope('A', '.box { color: red; }')!
	b := css.scope('B', '.box { color: blue; }')!
	assert a.rename('.box')! != b.rename('.box')!
}

fn test_root_tokens_pass_through_unscoped() {
	out := css.scope('Theme', ':root { --fg: #000; }')!
	// global custom properties must NOT be scoped
	assert out.css.contains(':root')
	assert out.css.contains('--fg')
}

fn test_atomize_dedupes_identical_declarations() {
	sheet := css.atomize([
		css.scope('A', '.x { padding: .5rem 1rem; }')!,
		css.scope('B', '.y { padding: .5rem 1rem; }')!,
	])!
	// the `padding:.5rem 1rem` declaration is emitted once and shared
	assert sheet.text.count('padding:.5rem 1rem') == 1 || sheet.text.count('padding: .5rem 1rem') == 1
}

fn test_tree_shakes_unreferenced_rules() {
	// `.used` is referenced by a template; `.dead` is not
	sheet := css.atomize_with_usage([
		css.scope('C', '.used { color: green; } .dead { color: red; }')!,
	], used_classes: ['used'])!
	assert sheet.text.contains('green')
	assert !sheet.text.contains('red')
}

fn test_emits_single_stylesheet() {
	sheet := css.atomize([
		css.scope('A', '.a { margin: 0; }')!,
		css.scope('B', '.b { margin: 0; }')!,
	])!
	assert sheet.filename.ends_with('.css')
	assert sheet.text.len > 0
}

fn test_media_queries_are_preserved() {
	out := css.scope('Resp', '@media (min-width: 40rem) { .grid { display: grid; } }')!
	assert out.css.contains('@media')
	assert out.css.contains('display: grid')
}
