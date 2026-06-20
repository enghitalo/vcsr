// Example: the minimum vcsr app — app bootstrap only.
// The Counter component is the triplet counter.v / counter.html / counter.css,
// which vcsr's implemented pipeline compiles to counter.gen.v (see README).
// `vcsr.new_app`/`render`/`mount` are the runtime library — the remaining
// roadmap, alongside the `vcsr` CLI and browser-wasm emission.
module main

import vcsr

fn main() {
	mut app := vcsr.new_app(root: '#app')
	app.render(Counter)
	app.mount()
}
