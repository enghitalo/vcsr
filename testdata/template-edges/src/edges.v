// Edges — the template language's edge cases in one component. The native test
// (edges_test.v) and the Chrome check (../check.mjs) both compare its render
// with ../expected.html, so the mock DOM and the browser must agree.
module main

import vcsr { Signal, signal }

@[component]
struct Edges {
mut:
	open  &Signal[bool]     = signal(true)
	items &Signal[[]string] = signal(['a', 'b'])
	first &Signal[string]   = signal('Ada')
	last  &Signal[string]   = signal('Lovelace')
	msg   &Signal[string]   = signal('')
	price &Signal[f64]      = signal(3.14159)
	n     &Signal[int]      = signal(255)
	code  &Signal[string]   = signal('x := 1')
	type  string            = 'search'
}

fn (mut e Edges) toggle() {
	e.open.set(!e.open.get())
}

fn (mut e Edges) add() {
	mut xs := e.items.get().clone()
	xs << 'c'
	e.items.set(xs)
}
