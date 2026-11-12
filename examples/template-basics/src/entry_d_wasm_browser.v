// Browser-wasm entry (compiled only with -d wasm_browser): boot() builds the
// Greeting's live view and mounts it into #app.
module main

import vcsr.runtime

// main is required by V but never runs under the reactor model: the host calls
// boot() (see vcsr_host.js).
fn main() {}

// a pointer global, filled by boot(): see examples/counter/src/entry_d_wasm_browser.v
__global (
	g_view     runtime.View
	g_greeting &Greeting = unsafe { nil }
)

@[export: 'boot']
pub fn boot() {
	g_greeting = &Greeting{}
	g_view = g_greeting.view()
	runtime.mount_view(g_view, '#app')
}
