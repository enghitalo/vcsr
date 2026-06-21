// Phase 12 — the runtime's reactive core (vcsr.runtime, slice 1: signals).
//
// The generated view() binds each template slot to a closure that reads signals;
// a write must re-run exactly the effects (slot updates) that read it. These pin
// that fine-grained behavior, tested directly (no browser/DOM needed).
//
// `signal()` returns a heap `&Signal`, so a closure capturing it (V captures by
// value) shares the same instance — exactly how the generated binds capture it.
// The effect stack is a global, so run with:
//   v -enable-globals test tests/phase_12_runtime_signals_test.v
module main

import vcsr { effect, signal }

fn test_get_set_update() {
	mut s := signal(10)
	assert s.get() == 10
	s.set(42)
	assert s.get() == 42
	s.update(fn (x int) int {
		return x + 1
	})
	assert s.get() == 43
}

fn test_effect_runs_immediately_and_on_change() {
	// A derived signal stands in for a slot's text binding: the effect reads
	// `count` and writes `doubled`; a write to count must re-run it.
	mut count := signal(2)
	mut doubled := signal(0)
	effect(fn [mut count, mut doubled] () {
		doubled.set(count.get() * 2)
	})
	assert doubled.peek() == 4 // ran once on creation
	count.set(5)
	assert doubled.peek() == 10 // re-ran on the write it depends on
	count.set(7)
	assert doubled.peek() == 14
}

fn test_effect_only_reruns_for_signals_it_read() {
	mut a := signal(1)
	mut b := signal(100)
	mut mirror := signal(0)
	effect(fn [mut a, mut mirror] () {
		mirror.set(a.get())
	})
	assert mirror.peek() == 1
	b.set(200) // b has no subscriber → must NOT re-run the effect that reads `a`
	assert mirror.peek() == 1
	a.set(2)
	assert mirror.peek() == 2
}

fn test_peek_does_not_subscribe() {
	mut s := signal(3)
	mut mirror := signal(0)
	effect(fn [mut s, mut mirror] () {
		mirror.set(s.peek()) // peek must NOT create a dependency
	})
	assert mirror.peek() == 3
	s.set(9)
	assert mirror.peek() == 3 // unchanged: peek didn't subscribe
}

fn test_string_signal() {
	mut name := signal('a')
	name.set('b')
	assert name.get() == 'b'
}
