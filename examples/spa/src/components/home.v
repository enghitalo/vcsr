// Home (landing) route — LOGIC only (template: home.html, styles: home.css).
// Ships in core.wasm. Illustrative source.
module components

import vcsr { Signal, signal }
import store { AppStore }

@[component]
pub struct Home {
	vcsr.Component
mut:
	count Signal[int] = signal(0)
}

pub fn (mut h Home) inc() {
	h.count.update(fn (n int) int {
		return n + 1
	})
}

// Exposed to the template as `{{ doubled }}`; vcsr memoizes it as a computed.
pub fn (h Home) doubled() int {
	return h.count.get() * 2
}

// `@click="toggle_theme"` in the template; delegates to the injected store.
pub fn (mut h Home) toggle_theme() {
	h.store[AppStore]().toggle_theme()
}
