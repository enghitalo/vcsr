// Integration: the GENERATED greeting.gen.v, wired to the native runtime,
// renders every template-language feature and reacts to signal writes. html()
// serializes like the browser's innerHTML (references decoded, `<` escaped).
module main

import vcsr.css
import vcsr.runtime

// html renders the view without the scope attribute every element carries
fn unscoped(v runtime.View) string {
	return v.html().replace(' ${css.scope_attr('Greeting')}=""', '')
}

fn test_generated_greeting_renders_and_reacts() {
	mut g := Greeting{}
	dom := g.view()
	html := unscoped(dom)
	// text mixed with interpolations is one text slot
	assert html.contains('<h1>Hello, World!</h1>')
	assert dom.html().contains('<h1 ${css.scope_attr('Greeting')}="">') // scoped styles match it
	// an interpolation beside elements renders at its anchor, in place
	assert html.contains('<p class="stats">5<!----> characters, a <b>short</b> name — true<!----> that it')
	// string interpolation + an if-expression inside {{ }}
	assert html.contains('<p class="shouts">Shouted 0 times.</p>')
	// a void element with a two-way binding; static entities, decoded
	assert html.contains('<input placeholder="type a name">')
	assert html.contains('<footer>© 2026 · costs $0 · 1 &lt; 2</footer>')

	g.shout()
	html2 := unscoped(dom)
	assert html2.contains('<h1>Hello, WORLD!</h1>')
	assert html2.contains('Shouted 1 time.')

	g.name.set('Margaret Hamilton')
	assert unscoped(dom).contains('17<!----> characters, a <b>long</b> name — false<!---->')
	g.name.set('Zoë') // characters, not UTF-8 bytes
	assert unscoped(dom).contains('3<!----> characters, a <b>short</b> name')
}
