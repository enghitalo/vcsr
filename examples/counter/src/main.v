// Example: the minimum vcsr app — app bootstrap only.
// The Counter component is the triplet counter.v / counter.html / counter.css,
// which vcsr's implemented pipeline compiles to counter.gen.v (see README).
// new_app/render/mount are the runtime library (vcsr.runtime).
module main

import vcsr.runtime

fn main() {
	mut c := Counter{}
	mut app := runtime.new_app(root: '#app')
	app.render(mut c)
	app.mount()
}
