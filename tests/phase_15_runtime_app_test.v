// Phase 15 — the app runtime (vcsr.runtime, slice 4).
//
// new_app → render → mount wires a root component into a (mock) page and keeps
// it live: a signal write after mount re-patches the view. And a SHARED signal
// is the whole cross-component story — an event in one component re-patches a
// slot in another, with no event bus. Tested against the native backend.
//
//   v -enable-globals test tests/phase_15_runtime_app_test.v
module main

import vcsr { Signal, signal }
import vcsr.runtime { SlotDesc, Template, View, bind_event, bind_text, document, new_app, to_str }

// A component is any struct with view()/style(); its state is the signals it
// reads. Greeting renders a shared `who` signal into an <h1>.
struct Greeting {
mut:
	who &Signal[string]
}

fn (mut g Greeting) view() View {
	tpl := Template{
		html:  '<h1></h1>'
		slots: [SlotDesc{ kind: .text, path: [] }]
	}
	mut ins := tpl.instance()
	mut w := g.who
	bind_text(mut ins, 0, fn [mut w] () string {
		return w.get()
	})
	return ins.view()
}

fn (g Greeting) style() string {
	return '.greeting{}'
}

fn test_app_renders_mounts_and_stays_live() {
	mut who := signal('world')
	mut g := Greeting{
		who: who
	}
	mut app := new_app(root: '#app')
	app.render(mut g)
	app.mount()
	assert app.html() == '<h1>world</h1>'
	who.set('vcsr') // a signal write after mount re-patches the live view
	assert app.html() == '<h1>vcsr</h1>'
	assert !document().is_undefined() // mount ensured the host document exists
}

// The cross-component answer: one shared signal IS the store. Two independent
// component instances capture it; an event in the "Bumper" re-patches the
// "Label" — no parent, no event bus, just the reactive graph.
fn test_shared_signal_is_the_cross_component_store() {
	mut store := signal(0)

	// "Label" — displays the store.
	label_tpl := Template{
		html:  '<span></span>'
		slots: [SlotDesc{ kind: .text, path: [] }]
	}
	mut label := label_tpl.instance()
	mut s_read := store
	bind_text(mut label, 0, fn [mut s_read] () string {
		return to_str(s_read.get())
	})

	// "Bumper" — a button that increments the store.
	bump_tpl := Template{
		html:  '<button>+</button>'
		slots: [SlotDesc{ kind: .event, path: [], name: 'click' }]
	}
	mut bump := bump_tpl.instance()
	mut s_write := store
	bind_event(mut bump, 0, fn [mut s_write] () {
		s_write.update(fn (x int) int {
			return x + 1
		})
	})

	label_dom := label.view()
	assert label_dom.html() == '<span>0</span>'
	bump.dispatch(0, 'click') // event in the Bumper instance...
	assert label_dom.html() == '<span>1</span>' // ...re-patches the Label instance
	bump.dispatch(0, 'click')
	assert label_dom.html() == '<span>2</span>'
}

// Watcher counts how many times its slot effect runs, so a test can prove the
// old view's effect is gone after a re-render (no leak).
struct Watcher {
mut:
	src  &Signal[int]
	runs &Signal[int]
}

fn (mut w Watcher) view() View {
	tpl := Template{
		html:  '<i></i>'
		slots: [SlotDesc{ kind: .text, path: [] }]
	}
	mut ins := tpl.instance()
	mut src := w.src
	mut runs := w.runs
	bind_text(mut ins, 0, fn [mut src, mut runs] () string {
		runs.update(fn (x int) int {
			return x + 1
		})
		return to_str(src.get())
	})
	return ins.view()
}

fn (w Watcher) style() string {
	return ''
}

// Re-rendering (a router swapping the root) must dispose the previous view's
// effect — otherwise a single signal write would fire BOTH the old and the new.
fn test_re_render_disposes_previous_view() {
	mut src := signal(0)
	mut runs := signal(0)
	mut w1 := Watcher{
		src:  src
		runs: runs
	}
	mut app := new_app(root: '#x')
	app.render(mut w1) // runs → 1
	mut w2 := Watcher{
		src:  src
		runs: runs
	}
	app.render(mut w2) // disposes w1's effect, runs w2's → 2
	before := runs.peek()
	src.set(5) // only ONE live effect should fire
	assert runs.peek() == before + 1 // +1, not +2 (w1 didn't leak)
}

// unmount disposes the live view: a later signal write patches nothing.
fn test_unmount_detaches_and_clears() {
	mut who := signal('x')
	mut g := Greeting{
		who: who
	}
	mut app := new_app(root: '#app')
	app.render(mut g)
	app.mount()
	assert app.html() == '<h1>x</h1>'
	app.unmount()
	assert app.html() == '' // view dropped
	who.set('y') // detached → must not patch (and must not crash)
	assert app.html() == ''
}
