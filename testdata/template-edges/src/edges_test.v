// The GENERATED edges.gen.v on the native mock: it renders exactly the markup
// Chrome renders (../expected.html, checked there by ../check.mjs), and its
// @if/@for anchors follow their signals.
module main

import os

const expected = (os.read_file(os.join_path(@DIR, '..', 'expected.html')) or { panic(err) }).trim_space()

fn test_native_render_matches_the_browser() {
	mut e := Edges{}
	dom := e.view()
	assert dom.html() == expected
}

fn test_if_and_for_anchors_follow_their_signals() {
	mut e := Edges{}
	dom := e.view()
	e.toggle()
	e.add()
	html := dom.html()
	assert html.contains('<section class="if"><!--@if false--><button')
	assert html.contains('<ul class="for"><!--@for 3--></ul>')
	e.first.set('<Grace>')
	assert dom.html().contains('<p class="who">Hello, &lt;Grace&gt; Lovelace!</p>')
}
