// Phase 14 — the Template/bind engine (vcsr.runtime, slice 3).
//
// A compiled component is a static skeleton + a slot table. instance() clones
// the skeleton; bind_* wires each slot to the reactive layer; a signal write
// re-runs ONLY the slots that read it and patches the live node. These pin that
// loop end to end against the native mock DOM (no browser).
//
//   v -enable-globals test tests/phase_14_runtime_engine_test.v
module main

import vcsr { signal }
import vcsr.runtime { SlotDesc, Template, bind_attr, bind_event, bind_if, bind_list, bind_text,
	bind_value, to_str }

// The counter, exactly as codegen would emit it: two text slots reading one
// signal + a click handler that writes it. The full clone → bind → patch loop.
fn test_counter_text_and_event_loop() {
	mut count := signal(2)
	tpl := Template{
		html:  '<main class="counter"><h1></h1><p class="muted">double <span></span></p><button>+1</button></main>'
		slots: [
			SlotDesc{ kind: .text, path: [0] }, // h1
			SlotDesc{ kind: .text, path: [1, 0] }, // span inside p (nested path)
			SlotDesc{ kind: .event, path: [2], name: 'click' }, // button
		]
	}
	mut ins := tpl.instance()
	bind_text(mut ins, 0, fn [mut count] () string {
		return to_str(count.get())
	})
	bind_text(mut ins, 1, fn [mut count] () string {
		return to_str(count.get() * 2)
	})
	bind_event(mut ins, 2, fn [mut count] () {
		count.update(fn (x int) int {
			return x + 1
		})
	})
	dom := ins.view()
	assert dom.html().contains('<h1>2</h1>')
	assert dom.html().contains('double <span>4</span>') // nested slot + leading text kept
	assert dom.html().contains('<button>+1</button>') // static text untouched

	ins.dispatch(2, 'click') // user clicks → count→3 → both text slots re-patch
	assert dom.html().contains('<h1>3</h1>')
	assert dom.html().contains('<span>6</span>')
}

fn test_attr_binding_follows_signal() {
	mut cls := signal('on')
	tpl := Template{
		html:  '<div><span></span></div>'
		slots: [SlotDesc{ kind: .attr, path: [0], name: 'class' }]
	}
	mut ins := tpl.instance()
	bind_attr(mut ins, 0, 'class', fn [mut cls] () string {
		return cls.get()
	})
	dom := ins.view()
	assert dom.html().contains('<span class="on">')
	cls.set('off')
	assert dom.html().contains('<span class="off">')
}

fn test_if_toggles_presence() {
	mut show := signal(true)
	tpl := Template{
		html:  '<div><p></p></div>'
		slots: [SlotDesc{ kind: .cond, path: [0] }]
	}
	mut ins := tpl.instance()
	bind_if(mut ins, 0, fn [mut show] () bool {
		return show.get()
	})
	dom := ins.view()
	assert dom.html().contains('<p>')
	show.set(false)
	assert !dom.html().contains('<p>') // removed from the render
	show.set(true)
	assert dom.html().contains('<p>') // and back
}

fn test_two_way_value_binding() {
	mut name := signal('alice')
	tpl := Template{
		html:  '<form><textarea></textarea></form>'
		slots: [SlotDesc{ kind: .bind, path: [0] }]
	}
	mut ins := tpl.instance()
	bind_value(mut ins, 0, fn [mut name] () string {
		return name.get()
	}, fn [mut name] (v string) {
		name.set(v)
	})
	assert ins.value_of(0) == 'alice' // value follows the signal...
	name.set('carol')
	assert ins.value_of(0) == 'carol' // ...on change too
	ins.input(0, 'bob') // user types → writes back...
	assert name.get() == 'bob'
	assert ins.value_of(0) == 'bob' // ...and the value re-syncs
}

fn test_list_length_is_reactive() {
	mut n := signal(2)
	tpl := Template{
		html:  '<ul><li></li></ul>'
		slots: [SlotDesc{ kind: .list, path: [0] }]
	}
	mut ins := tpl.instance()
	bind_list(mut ins, 0, fn [mut n] () int {
		return n.get()
	})
	dom := ins.view()
	assert dom.html().contains('data-count="2"')
	n.set(5)
	assert dom.html().contains('data-count="5"')
}

// Text that follows an element must stay after it (ordered children), and a
// text slot resolves to the right nested element regardless of surrounding text.
fn test_interleaved_text_keeps_source_order() {
	mut x := signal('Y')
	tpl := Template{
		html:  '<p>before<b></b>after</p>'
		slots: [SlotDesc{ kind: .text, path: [0] }] // the <b>, element-index 0
	}
	mut ins := tpl.instance()
	bind_text(mut ins, 0, fn [mut x] () string {
		return x.get()
	})
	dom := ins.view()
	assert dom.html() == '<p>before<b>Y</b>after</p>' // not "beforeafter<b>"
}

// Void elements get no closing tag (valid HTML).
fn test_void_elements_have_no_closing_tag() {
	tpl := Template{
		html:  '<form><input/></form>'
		slots: []
	}
	mut ins := tpl.instance()
	dom := ins.view()
	assert dom.html() == '<form><input></form>'
}

// Disposing an instance detaches its slot effects: a later signal write must not
// patch the (now unmounted) tree — the leak the review flagged.
fn test_dispose_detaches_slot_effects() {
	mut count := signal(1)
	tpl := Template{
		html:  '<div><span></span></div>'
		slots: [SlotDesc{ kind: .text, path: [0] }]
	}
	mut ins := tpl.instance()
	bind_text(mut ins, 0, fn [mut count] () string {
		return to_str(count.get())
	})
	dom := ins.view()
	assert dom.html().contains('<span>1</span>')
	count.set(2)
	assert dom.html().contains('<span>2</span>')
	ins.dispose()
	count.set(3) // detached → the unmounted node must not be patched
	assert dom.html().contains('<span>2</span>')
}
