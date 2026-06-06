// Home (landing) route: signals + computed + a shared Button + theme toggle.
// Ships in core.wasm. Illustrative source.
module components

import vcsr { Signal, computed, signal }
import shared { Button }
import store { AppStore }

@[component]
pub struct Home {
	vcsr.Component
mut:
	count Signal[int] = signal(0)
}

pub fn (mut h Home) view() vcsr.View {
	doubled := computed(fn [h] () int {
		return h.count.get() * 2
	})
	store_ := h.store[AppStore]() // injected global store

	return $vui('
		<main class="home">
			<header>
				<h1>vcsr SPA</h1>
				<button class="ghost" @click=${store_.toggle_theme}>theme</button>
			</header>

			<section class="counter">
				<p class="value">${h.count}</p>
				<p class="muted">double: ${doubled}</p>
				${Button{ label: "+1", on_click: h.inc }}
			</section>

			<nav>
				<a @link="/todos">todos →</a>
				<a @link="/reports/42">reports →</a>
			</nav>
		</main>
	')
}

pub fn (mut h Home) inc() {
	h.count.update(fn (n int) int {
		return n + 1
	})
}

pub fn (h Home) style() string {
	return $css('
		.home    { display: grid; gap: 1.5rem; padding: 2rem; max-width: 28rem; }
		header   { display: flex; justify-content: space-between; align-items: center; }
		.value   { font-size: 3rem; font-weight: 700; margin: 0; }
		.muted   { color: var(--fg-muted); }
		.ghost   { opacity: .6; background: none; border: none; cursor: pointer; }
		nav      { display: flex; gap: 1rem; }
	')
}
