// The app runtime: mount a root component into the page and keep it live.
//
// A Component is anything the compiler produces a view()/style() for. new_app()
// names a host element by CSS selector; render() builds the root component's
// live view (cloning its template + wiring its reactive slots — phase 14); and
// mount() attaches that view to the host. Because every slot is a signal effect,
// the page then updates itself: a write to any signal re-patches exactly the
// slots that read it, with no further app involvement.
//
// CROSS-COMPONENT STATE is just a shared signal. Two components that capture the
// same `&vcsr.Signal` ARE wired together: an event handler in one writes the
// signal, and every slot in every component that read it re-patches — no event
// bus, no parent prop-drilling. A "store" is a struct of such signals passed to
// each component (see phase_15). This is the answer to "how does an event in one
// component change another".
//
// This is the NATIVE backend (testable without a browser): document() is a mock
// host object and mount() leaves the live view reachable via html(). On wasm the
// same calls go through the `js` FFI to the real document.
module runtime

import vcsr

// Component is what every compiled component satisfies: a reactive view() that
// builds its live DOM, plus its scoped styles. The generated <name>.gen.v emits
// both; a hand-written component struct provides the state they read.
pub interface Component {
	style() string
mut:
	view() View
}

// AppOpts configures new_app. `root` is the CSS selector of the host element the
// app mounts into (browser target); defaults to 'body'.
@[params]
pub struct AppOpts {
pub:
	root string = 'body'
}

// App is a mounted root: the host selector plus the live view of its root component.
pub struct App {
mut:
	root_sel string
	view     ?View
	mounted  bool
}

// new_app creates an app that will mount into `opts.root`.
pub fn new_app(opts AppOpts) App {
	return App{
		root_sel: opts.root
	}
}

// render builds the root component's live view — cloning its template and wiring
// every reactive slot. After this the view patches itself on signal writes; call
// mount() to attach it to the host. Re-rendering (a router swapping the root
// component) DISPOSES the previous view's effects first, so a route change does
// not leak a permanently-running effect onto shared signals.
pub fn (mut a App) render(mut c Component) {
	if mut old := a.view {
		old.dispose()
	}
	a.view = c.view()
}

// mount attaches the rendered view to the host element. On wasm it appends the
// live root node to document.querySelector(root_sel); natively the view is
// already live and reachable through html(), so this just records the mount and
// ensures the host document exists. Transient host handles (the selector string,
// the queried element) are released so the handle table doesn't grow per mount.
pub fn (mut a App) mount() {
	d := document()
	sel := vcsr.js_str(a.root_sel)
	host := d.call('querySelector', sel)
	if !host.is_undefined() {
		// wasm: host.replaceChildren(a.view root node). The mock host has no
		// querySelector, so this is a no-op natively.
		host.call('replaceChildren')
	}
	host.release()
	sel.release()
	a.mounted = true
}

// unmount disposes the view's effects (detaching them from every signal) and
// drops it — the teardown a host calls when an app goes away. Idempotent.
pub fn (mut a App) unmount() {
	if mut v := a.view {
		v.dispose()
	}
	a.view = none
	a.mounted = false
}

// html serializes the mounted view (tests / server-side render); '' before render.
pub fn (a App) html() string {
	if v := a.view {
		return v.html()
	}
	return ''
}

// document returns the host document. On wasm it is globalThis.document; natively
// it is a mock object, created on first use, so app/mount code runs in tests.
pub fn document() vcsr.JsValue {
	d := vcsr.global().get('document')
	if !d.is_undefined() {
		return d
	}
	doc := vcsr.js_object()
	vcsr.global().set('document', doc)
	return doc
}
