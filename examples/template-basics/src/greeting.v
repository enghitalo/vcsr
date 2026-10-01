// Greeting — LOGIC only; the template is greeting.html. vcsr generates
// greeting.gen.v (view()/style()) from the pair.
module main

import vcsr { Signal, signal }

@[component]
struct Greeting {
mut:
	name   &Signal[string] = signal('World')
	shouts &Signal[int]    = signal(0)
}

// size is a computed: the template reads it as `{{ size }}`.
fn (mut g Greeting) size() string {
	n := g.name.get().len
	return if n < 6 {
		'short'
	} else if n < 12 {
		'medium'
	} else {
		'long'
	}
}

fn (mut g Greeting) shout() {
	g.name.set(g.name.get().to_upper())
	g.shouts.set(g.shouts.get() + 1)
}

fn (mut g Greeting) reset() {
	g.name.set('World')
	g.shouts.set(0)
}
