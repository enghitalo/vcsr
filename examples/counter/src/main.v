// Example: the minimum vcsr app — one component, rendered 100% client-side.
// Illustrative source; the compiler is not implemented yet (see repo README).
module main

import vcsr { Signal, computed, signal }

@[component]
struct Counter {
	vcsr.Component
mut:
	count Signal[int] = signal(0)
}

fn (mut c Counter) view() vcsr.View {
	// `computed` is memoized: recomputes only when `count` changes.
	doubled := computed(fn [c] () int {
		return c.count.get() * 2
	})

	// `$vui` is compiled at build time into a static HTML skeleton (embedded in
	// the WASM) + a slot table. Only `${c.count}` and `${doubled}` are dynamic;
	// a change patches just those text nodes.
	return $vui('
		<main class="counter">
			<h1>${c.count}</h1>
			<p class="muted">double: ${doubled}</p>
			<button @click=${c.inc}>+1</button>
		</main>
	')
}

fn (mut c Counter) inc() {
	c.count.update(fn (n int) int {
		return n + 1
	})
}

// Co-located styles, scoped to `Counter` and tree-shaken at build time.
fn (c Counter) style() string {
	return $css('
		.counter { display: grid; gap: .5rem; padding: 2rem; max-width: 20rem; }
		.muted   { color: var(--muted, #888); }
		button   { padding: .5rem 1rem; border-radius: .5rem; cursor: pointer; }
	')
}

fn main() {
	mut app := vcsr.new_app(root: '#app')
	app.render(Counter)
	app.mount()
}
