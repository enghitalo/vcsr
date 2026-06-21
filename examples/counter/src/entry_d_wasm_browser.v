// Browser-wasm entry for the counter (compiled only with -d wasm_browser).
//
// The native entry is main_notd_wasm_browser.v (uses the App runtime). On wasm the
// App/Component layer is native-only (it leans on the js_ffi mock, whose maps
// don't run on wasm), so this entry drives the generated view() directly: boot()
// mounts; inc() is the click entry point. The reactive layer (signals/effects) and
// the wasm rendering backend are map-free and closure-free, so this runs in wasm.
module main

import vcsr.runtime

// main is required by V for `module main`, but is dead under the reactor model
// (-mexec-model=reactor -Wl,--no-entry): the host calls boot()/inc() directly.
fn main() {}

__global (
	g_view    runtime.View
	g_counter Counter
)

// boot builds the counter's live view (cloning the host template + wiring the
// reactive slots through host FFI) and mounts it into #app.
@[export: 'boot']
pub fn boot() {
	g_counter = Counter{}
	g_view = g_counter.view()
	runtime.mount_view(g_view, '#app')
}

// inc is the click entry point: bump the signal; the subscribed slot effects
// re-run and patch exactly the bound text nodes via host FFI.
@[export: 'inc']
pub fn inc() {
	g_counter.inc()
}
