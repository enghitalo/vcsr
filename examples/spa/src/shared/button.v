// A shared design-system component. Used by more than one route, so the build
// hoists it into core.wasm: one copy, its <template> registered once, cloned by
// every route. Splitting does not duplicate it. Illustrative source.
module shared

import vcsr

@[component]
pub struct Button {
	vcsr.Component
pub:
	label    string
	on_click fn ()
}

pub fn (b Button) view() vcsr.View {
	return $vui('<button class="btn" @click=${b.on_click}>${b.label}</button>')
}

pub fn (b Button) style() string {
	return $css('
		.btn { padding: .5rem 1rem; border: 1px solid var(--border);
		       border-radius: .5rem; background: var(--surface); color: var(--fg);
		       cursor: pointer; }
		.btn:hover { background: var(--surface-hover); }
	')
}
