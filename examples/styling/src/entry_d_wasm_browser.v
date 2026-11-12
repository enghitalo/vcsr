// Browser-wasm entry (compiled only with -d wasm_browser): boot() builds the
// Panel's and the Badge's live views and mounts both into #app. Each view's
// instance() adds its component's scoped stylesheet to the page, once.
module main

import vcsr.runtime

// main is required by V but never runs under the reactor model: the host calls
// boot() (see vcsr_host.js).
fn main() {}

// pointer globals, filled by boot(): see examples/counter/src/entry_d_wasm_browser.v
__global (
	g_panel_view runtime.View
	g_badge_view runtime.View
	g_panel      &Panel = unsafe { nil }
	g_badge      &Badge = unsafe { nil }
)

@[export: 'boot']
pub fn boot() {
	g_panel = &Panel{}
	g_panel_view = g_panel.view()
	runtime.mount_view(g_panel_view, '#app')
	g_badge = &Badge{}
	g_badge_view = g_badge.view()
	runtime.mount_view(g_badge_view, '#app')
}
