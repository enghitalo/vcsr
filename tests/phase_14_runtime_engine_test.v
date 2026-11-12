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
import vcsr.runtime { SlotDesc, Template, bind_attr, bind_event, bind_if, bind_if_ctx, bind_list, bind_text, bind_value, to_str }

// The counter, exactly as codegen would emit it: two text slots reading one
// signal + a click handler that writes it. The full clone → bind → patch loop.
fn test_counter_text_and_event_loop() {
	mut count := signal(2)
	tpl := Template{
		html:  '<main class="counter"><h1></h1><p class="muted">double <span></span></p><button>+1</button></main>'
		slots: [
			SlotDesc{
				kind: .text
				path: [0]
			}, // h1
			SlotDesc{
				kind: .text
				path: [1, 0]
			}, // span inside p (nested path)
			SlotDesc{
				kind: .event
				path: [2]
				name: 'click'
			}, // button
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

// @if and @for slots are ANCHORS: an empty comment in the container (what
// slots/codegen emit, #28). Until roadmap items 4/5 render their rows, the
// binding keeps its expression live and shows it on the anchor; it never
// touches an element (#16: a comment has no style or attributes).
fn test_if_anchor_shows_the_live_condition() {
	mut show := signal(true)
	tpl := Template{
		html:  '<div><b>x</b><!----></div>'
		slots: [SlotDesc{ kind: .cond, path: [], anchor: 0 }]
	}
	mut ins := tpl.instance()
	bind_if(mut ins, 0, fn [mut show] () bool {
		return show.get()
	})
	dom := ins.view()
	assert dom.html() == '<div><b>x</b><!--@if true--></div>'
	show.set(false)
	assert dom.html() == '<div><b>x</b><!--@if false--></div>'
}

struct Flag {
mut:
	on &vcsr.Signal[bool]
}

fn flag_on(ctx voidptr) bool {
	f := unsafe { &Flag(ctx) }
	return f.on.get()
}

fn test_if_anchor_ctx_binding_matches_the_closure_one() {
	mut f := Flag{
		on: signal(false)
	}
	tpl := Template{
		html:  '<p><!----></p>'
		slots: [SlotDesc{ kind: .cond, path: [], anchor: 0 }]
	}
	mut ins := tpl.instance()
	bind_if_ctx(mut ins, 0, voidptr(&f), flag_on)
	dom := ins.view()
	assert dom.html() == '<p><!--@if false--></p>'
	f.on.set(true)
	assert dom.html() == '<p><!--@if true--></p>'
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

fn test_for_anchor_shows_the_live_count() {
	mut n := signal(2)
	tpl := Template{
		html:  '<ul><!----></ul>'
		slots: [SlotDesc{ kind: .list, path: [], anchor: 0 }]
	}
	mut ins := tpl.instance()
	bind_list(mut ins, 0, fn [mut n] () int {
		return n.get()
	})
	dom := ins.view()
	assert dom.html() == '<ul><!--@for 2--></ul>'
	n.set(5)
	assert dom.html() == '<ul><!--@for 5--></ul>'
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

// --- the mock parses its skeleton as HTML and serializes like the DOM ---------

// #20: `{{{{` leaves a literal `{{` in the skeleton. That is text to the browser,
// and to the mock, which parses the skeleton as HTML, not as a template.
fn test_literal_braces_in_the_skeleton_are_text() {
	mut x := signal('X')
	tpl := Template{
		html:  '<div><p>type {{ to open, {{x}} too</p><b></b></div>'
		slots: [SlotDesc{ kind: .text, path: [1] }]
	}
	mut ins := tpl.instance()
	bind_text(mut ins, 0, fn [mut x] () string {
		return x.get()
	})
	assert ins.view().html() == '<div><p>type {{ to open, {{x}} too</p><b>X</b></div>'
}

// #25: html() serializes like the browser's innerHTML. Entities in the skeleton
// are decoded when it is parsed; text and attribute values are escaped on the
// way out, so markup in a value or in decoded text never becomes a live tag.
fn test_html_escapes_text_and_attributes_like_the_dom() {
	mut v := signal('<b>&"x"</b>')
	tpl := Template{
		html:  '<p title="a &amp; &quot;b&quot;">Tom &amp; Jerry &mdash; 1 &lt; 2<span></span><i></i></p>'
		slots: [SlotDesc{ kind: .text, path: [0] }, SlotDesc{ kind: .attr, path: [1], name: 'title' }]
	}
	mut ins := tpl.instance()
	bind_text(mut ins, 0, fn [mut v] () string {
		return v.get()
	})
	bind_attr(mut ins, 1, 'title', fn [mut v] () string {
		return v.get()
	})
	assert ins.view().html() == '<p title="a &amp; &quot;b&quot;">Tom &amp; Jerry — 1 &lt; 2<span>&lt;b&gt;&amp;"x"&lt;/b&gt;</span><i title="&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;"></i></p>'
	raw := Template{
		html:  '<div><style>a > b { content: "&amp;" }</style>\u00a0</div>'
		slots: []
	}
	mut rins := raw.instance()
	assert rins.view().html() == '<div><style>a > b { content: "&amp;" }</style>&nbsp;</div>'
}

// #33: the mock keeps the skeleton's whitespace as written, as the browser does
// (no template condensing), e.g. the space a dropped user comment left behind.
fn test_skeleton_whitespace_is_kept_as_written() {
	for html in ['<div><span>a</span><span> <b>b</b></span></div>',
		'<div><b>x</b><span><b>y</b> </span>z</div>', '<p>\n  a  <b>b</b>\n</p>'] {
		tpl := Template{
			html:  html
			slots: []
		}
		mut ins := tpl.instance()
		assert ins.view().html() == html
	}
}

@[heap]
struct Log {
mut:
	lines []string
}

// every handler for an event runs, in order, and input() runs the @bind writer
// before @input handlers, as the browser does
fn test_every_handler_runs_and_input_writes_first() {
	mut name := signal('a')
	mut log := &Log{}
	tpl := Template{
		html:  '<div><input></div>'
		slots: [SlotDesc{
			kind: .bind
			path: [0]
		}, SlotDesc{
			kind: .event
			path: [0]
			name: 'input'
		}, SlotDesc{
			kind: .event
			path: [0]
			name: 'input'
		}]
	}
	mut ins := tpl.instance()
	bind_value(mut ins, 0, fn [mut name] () string {
		return name.get()
	}, fn [mut name] (v string) {
		name.set(v)
	})
	bind_event(mut ins, 1, fn [mut name, mut log] () {
		log.lines << 'one:${name.peek()}'
	})
	bind_event(mut ins, 2, fn [mut log] () {
		log.lines << 'two'
	})
	ins.input(0, 'xyz')
	assert log.lines == ['one:xyz', 'two']
}

// the mock reads the skeleton like the browser: names folded, raw text kept
fn test_skeleton_names_fold_and_raw_text_round_trips() {
	tpl := Template{
		html:  '<DIV TabIndex="0"><xmp>a &amp; <b></xmp><P>x</P></DIV>'
		slots: []
	}
	mut ins := tpl.instance()
	assert ins.view().html() == '<div tabindex="0"><xmp>a &amp; <b></xmp><p>x</p></div>'
}

struct Theme {
mut:
	on   &vcsr.Signal[bool]
	kind &vcsr.Signal[string]
}

fn theme_on(ctx voidptr) bool {
	t := unsafe { &Theme(ctx) }
	return t.on.get()
}

fn theme_kind(ctx voidptr) string {
	t := unsafe { &Theme(ctx) }
	return t.kind.get()
}

// class:name toggles one class and :class adds the classes it names, both
// through classList: the static class and each other's classes stay
fn test_class_toggle_and_classes_keep_the_static_class() {
	mut t := Theme{
		on:   signal(false)
		kind: signal('big red')
	}
	tpl := Template{
		html:  '<div class="card"></div>'
		slots: [SlotDesc{
			kind: .toggle
			path: []
			name: 'on'
		}, SlotDesc{
			kind: .classes
			path: []
		}]
		css:   '.card{x:1}'
	}
	mut ins := tpl.instance()
	runtime.bind_toggle_ctx(mut ins, 0, voidptr(&t), theme_on)
	runtime.bind_classes_ctx(mut ins, 1, voidptr(&t), theme_kind)
	dom := ins.view()
	assert dom.html() == '<div class="card big red"></div>'
	t.on.set(true)
	t.kind.set('red small')
	assert dom.html() == '<div class="card red on small"></div>'
	t.on.set(false)
	assert dom.html() == '<div class="card red small"></div>'
	// a component's stylesheet is added once, however many instances
	_ := tpl.instance()
	assert runtime.styles().filter(it == '.card{x:1}').len == 1
}

// :class never removes a class the static `class` or a class:x provides, and
// the class list stays de-duplicated, as classList keeps it
fn test_classes_leave_owned_classes_and_dedupe() {
	mut t := Theme{
		on:   signal(false)
		kind: signal('btn x y y')
	}
	tpl := Template{
		html:  '<section class="btn btn"></section>'
		slots: [SlotDesc{
			kind: .toggle
			path: []
			name: 'x'
		}, SlotDesc{
			kind: .classes
			path: []
			name: 'btn x'
		}]
	}
	mut ins := tpl.instance()
	runtime.bind_toggle_ctx(mut ins, 0, voidptr(&t), theme_on)
	runtime.bind_classes_ctx(mut ins, 1, voidptr(&t), theme_kind)
	dom := ins.view()
	assert dom.html() == '<section class="btn x y"></section>'
	t.on.set(true)
	t.kind.set('y')
	assert dom.html() == '<section class="btn x y"></section>'
}
