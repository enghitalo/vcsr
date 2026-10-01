// Integration: the GENERATED greeting.gen.v, wired to the native runtime,
// renders every template-language feature and reacts to signal writes.
module main

fn test_generated_greeting_renders_and_reacts() {
	mut g := Greeting{}
	dom := g.view()
	html := dom.html()
	// text mixed with interpolations is one text slot
	assert html.contains('<h1>Hello, World!</h1>')
	// an interpolation beside elements renders at its anchor, in place
	assert html.contains('<p class="stats">5<!----> characters, a <b>short</b> name &mdash; true<!----> that it')
	// string interpolation + an if-expression inside {{ }}
	assert html.contains('<p class="shouts">Shouted 0 times.</p>')
	// a void element with a two-way binding; static entities stay in the skeleton
	assert html.contains('<input placeholder="type a name">')
	assert html.contains('&copy; 2026 &middot; costs $0 &middot; 1 &lt; 2')

	g.shout()
	html2 := dom.html()
	assert html2.contains('<h1>Hello, WORLD!</h1>')
	assert html2.contains('Shouted 1 time.')

	g.name.set('Margaret Hamilton')
	assert dom.html().contains('17<!----> characters, a <b>long</b> name &mdash; false<!---->')
}
