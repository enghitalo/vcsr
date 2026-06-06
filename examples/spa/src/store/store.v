// Global reactive store. Lives in core.wasm; any signal read inside a view
// subscribes that exact DOM binding, so toggling the theme updates only the
// nodes that depend on it. Illustrative source.
module store

import vcsr { Signal, signal }

pub struct AppStore {
pub mut:
	theme Signal[string] = signal('light')
}

pub fn AppStore.new() &AppStore {
	return &AppStore{}
}

pub fn (mut s AppStore) toggle_theme() {
	s.theme.update(fn (t string) string {
		return if t == 'light' { 'dark' } else { 'light' }
	})
	// mirror onto <html data-theme="…">, which the CSS variables key off of
	vcsr.document().root().set_attr('data-theme', s.theme.get())
}
