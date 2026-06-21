// The reactive core of the vcsr runtime: fine-grained signals.
//
// A Signal holds a value plus the set of effects that have read it. Reading
// inside a running effect subscribes that effect; writing re-runs exactly its
// subscribers — O(live dependents), no diff, no virtual DOM. This is the
// machinery the generated `view()` binds slots to (see vcsr.runtime).
//
// Dependencies are tracked DYNAMICALLY: each run of an effect first detaches it
// from the signals it read last time, then re-attaches only to the ones it
// reads this time. So an effect whose expression branches (e.g. an `@if` guard,
// or `cond ? a : b`) never keeps a phantom dependency on a signal it stopped
// reading. Effects are also disposable, so a component instance can detach all
// of its slot bindings on unmount instead of leaking them onto long-lived
// signals (an unbounded memory + CPU leak otherwise).
//
// The "currently running effect" is a global stack — vcsr targets a
// single-threaded wasm guest, so this needs `-enable-globals` (natural for the
// wasm target; pass it to `v test` for the native runtime tests).
module vcsr

// Effect is a reactive computation re-run whenever a signal it read changes. It
// remembers how to detach from its current dependencies (one cleanup thunk per
// subscribed signal), so a re-run can drop dependencies it no longer reads and
// an owner can dispose it entirely.
@[heap]
pub struct Effect {
mut:
	action   fn () = unsafe { nil }
	cleanups []fn () // detach thunks for the signals subscribed on the last run
	disposed bool
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

// get reads the value and subscribes the currently-running effect (if any),
// recording on that effect how to unsubscribe again — so a later run that stops
// reading this signal can drop the dependency.
pub fn (mut s Signal[T]) get() T {
	if vcsr_effect_stack.len > 0 {
		mut e := vcsr_effect_stack.last()
		mut seen := false
		for x in s.subs {
			if voidptr(x) == voidptr(e) {
				seen = true
				break
			}
		}
		if !seen {
			s.subs << e
			e.cleanups << fn [mut s, e] [T] () {
				s.unsubscribe(e)
			}
		}
	}
	return s.val
}

// peek reads the value WITHOUT subscribing — use when you don't want a dependency.
pub fn (s &Signal[T]) peek() T {
	return s.val
}

// unsubscribe removes effect `e` from this signal's subscribers.
fn (mut s Signal[T]) unsubscribe(e &Effect) {
	for i, x in s.subs {
		if voidptr(x) == voidptr(e) {
			s.subs.delete(i)
			return
		}
	}
}

// set writes the value and re-runs every subscribed effect.
pub fn (mut s Signal[T]) set(v T) {
	s.val = v
	for mut e in s.subs.clone() {
		run_tracked(mut e)
	}
}

// update sets the value from a function of the current one.
pub fn (mut s Signal[T]) update(f fn (T) T) {
	s.set(f(s.val))
}

// effect runs `f` immediately, tracking the signals it reads, and re-runs it
// whenever any of them changes. Use effect_handle when you need to dispose it.
pub fn effect(f fn ()) {
	mut e := &Effect{
		action: f
	}
	run_tracked(mut e)
}

// effect_handle is effect() that returns the &Effect, so an owner (a component
// instance) can dispose it on unmount — see (mut Effect) dispose.
pub fn effect_handle(f fn ()) &Effect {
	mut e := &Effect{
		action: f
	}
	run_tracked(mut e)
	return e
}

// run_tracked detaches `e` from its previous dependencies, then runs it as the
// active effect so its reads re-subscribe it — dynamic dependency tracking.
fn run_tracked(mut e Effect) {
	if e.disposed {
		return
	}
	for c in e.cleanups {
		c()
	}
	e.cleanups = []
	vcsr_effect_stack << e
	e.action()
	vcsr_effect_stack.pop()
}

// dispose detaches the effect from every signal it reads and stops it re-running.
// A component instance disposes its slot effects on unmount (see runtime.dispose).
pub fn (mut e Effect) dispose() {
	for c in e.cleanups {
		c()
	}
	e.cleanups = []
	e.disposed = true
}
