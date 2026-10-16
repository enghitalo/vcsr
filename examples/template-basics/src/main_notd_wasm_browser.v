// Native entry (mock DOM), so the example also builds and tests without a browser.
module main

import vcsr.runtime

fn main() {
	mut g := Greeting{}
	mut app := runtime.new_app(root: '#app')
	app.render(mut g)
	app.mount()
	println(app.html())
}
