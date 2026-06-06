// Example: the minimum vcsr app — app bootstrap only.
// The Counter component is the triplet counter.v / counter.html / counter.css.
// Illustrative source; the compiler is not implemented yet (see repo README).
module main

import vcsr

fn main() {
	mut app := vcsr.new_app(root: '#app')
	app.render(Counter)
	app.mount()
}
