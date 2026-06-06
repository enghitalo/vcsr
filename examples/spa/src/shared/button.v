// Shared design-system component — LOGIC only (template: button.html, styles:
// button.css). Used by more than one route, so the build hoists it into
// core.wasm: one copy, its <template> registered once, cloned by every route.
// Illustrative source.
module shared

import vcsr

@[component]
pub struct Button {
	vcsr.Component
pub:
	label    string
	on_click fn ()
}
