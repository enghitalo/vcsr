// The reactive core of the vcsr runtime: fine-grained signals.
//
// A Signal holds a value plus the set of effects that have read it. Reading
// inside a running effect subscribes that effect; writing re-runs exactly its
// subscribers — O(dependents), no diff, no virtual DOM. This is the machinery
// the generated `view()` binds slots to (see vcsr.runtime).
//
// The "currently running effect" is a global stack — vcsr targets a
// single-threaded wasm guest, so this needs `-enable-globals` (natural for the
// wasm target; pass it to `v test` for the native runtime tests).
module vcsr

// Effect is a reactive computation re-run whenever a signal it read changes.
pub struct Effect {
mut:
	action fn () = unsafe { nil }
}

__global (
	vcsr_effect_stack []&Effect
)

// Signal[T] is a reactive cell: a value plus its subscriber effects.
pub struct Signal[T] {
mut:
	val  T
	subs []&Effect
}

// signal creates a reactive cell holding `v`. It returns a HEAP reference so the
// cell has a stable identity: a closure that captures it (V captures by value)
// copies the pointer, so reads and writes hit the same instance — which is what
// makes reactivity survive being wired into slot-binding closures.
pub fn signal[T](v T) &Signal[T] {
	return &Signal[T]{
		val: v
	}
}

// get reads the value and subscribes the currently-running effect (if any).
pub fn (mut s Signal[T]) get() T {
	if vcsr_effect_stack.len > 0 {
		e := vcsr_effect_stack.last()
		mut seen := false
		for x in s.subs {
			if voidptr(x) == voidptr(e) {
				seen = true
				break
			}
		}
		if !seen {
			s.subs << e
		}
	}
	return s.val
}

// peek reads the value WITHOUT subscribing — use when you don't want a dependency.
pub fn (s &Signal[T]) peek() T {
	return s.val
}

// set writes the value and re-runs every subscribed effect.
pub fn (mut s Signal[T]) set(v T) {
	s.val = v
	for e in s.subs.clone() {
		run_tracked(e)
	}
}

// update sets the value from a function of the current one.
pub fn (mut s Signal[T]) update(f fn (T) T) {
	s.set(f(s.val))
}

// effect runs `f` immediately, tracking the signals it reads, and re-runs it
// whenever any of them changes.
pub fn effect(f fn ()) {
	e := &Effect{
		action: f
	}
	run_tracked(e)
}

// run_tracked pushes `e` as the active effect, runs it (so its signal reads
// subscribe it), then pops — re-tracking dependencies on every run.
fn run_tracked(e &Effect) {
	vcsr_effect_stack << e
	e.action()
	vcsr_effect_stack.pop()
}
