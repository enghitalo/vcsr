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
// CLOSURE-FREE BY CONSTRUCTION (so it runs on wasm). An effect is a TOP-LEVEL
// function + a context pointer — never a capturing closure. V capturing closures
// (`fn [x] () {...}`) are lowered to runtime-generated executable memory, which
// wasm forbids: such a closure validates but TRAPS when called
// (`table index is out of bounds`). So the primitives codegen targets —
// `effect_ctx`/`effect_handle_ctx` and the per-signal detach — take an explicit
// `voidptr` context and a top-level `fn`, which lower to plain function-table
// indices that run everywhere. (`effect`/`effect_handle` keep the ergonomic
// closure form for hand-written NATIVE code and tests; they box the closure and
// are not wasm-portable.) See docs/examples/wasm-reactive/ and docs/WEB-API-SUPPORT.md.
//
// The "currently running effect" is a global stack — vcsr targets a
// single-threaded wasm guest, so this needs `-enable-globals` (natural for the
// wasm target; pass it to `v test` for the native runtime tests).
module vcsr

// Cleanup detaches one subscribed signal from an effect on the effect's next run
// (dynamic dependency tracking) or on dispose. It is closure-free: `sig` is the
// type-erased `&Signal[T]` and `detach` is a monomorphized `unsubscribe_signal[T]`
// (a plain function-table index, so it works on wasm).
struct Cleanup {
	sig    voidptr
	detach fn (sig voidptr, e &Effect)
}

// ClosureBox keeps a closure alive behind the closure-FREE Effect.action ABI, so
// the ergonomic `effect`/`effect_handle` (native-only) still work. The typed
// reference on Effect (`box`) keeps the GC from collecting it.
@[heap]
struct ClosureBox {
	f fn () = unsafe { nil }
}

// Effect is a reactive computation re-run whenever a signal it read changes.
// `action(ctx)` is a top-level fn + its context (no captures — see the module
// doc). It remembers how to detach from its current dependencies (one Cleanup per
// subscribed signal), so a re-run can drop dependencies it no longer reads and an
// owner can dispose it entirely.
@[heap]
pub struct Effect {
mut:
	action   fn (ctx voidptr) = unsafe { nil }
	ctx      voidptr
	box      &ClosureBox = unsafe { nil } // set only by the closure-API conveniences
	cleanups []Cleanup // detach records for the signals subscribed on the last run
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
// cell has a stable identity: everything that reads it (a slot's effect context)
// holds this same pointer, so reads and writes hit the same instance — which is
// what makes reactivity survive being wired into slot bindings.
pub fn signal[T](v T) &Signal[T] {
	return &Signal[T]{
		val: v
	}
}

// get reads the value and subscribes the currently-running effect (if any),
// recording on that effect how to unsubscribe again — so a later run that stops
// reading this signal can drop the dependency. The cleanup is closure-free: it
// stores `voidptr(s)` plus `unsubscribe_signal[T]` (a top-level generic fn).
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
			e.cleanups << Cleanup{
				sig:    voidptr(s)
				detach: unsubscribe_signal[T]
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

// unsubscribe_signal is the closure-free detach stored in a Cleanup: it casts the
// type-erased signal pointer back to `&Signal[T]` and unsubscribes `e`. Referenced
// as a value (`unsubscribe_signal[T]`) it is a plain function-table index, so it
// runs on wasm where a capturing-closure cleanup would trap.
fn unsubscribe_signal[T](sig voidptr, e &Effect) {
	mut s := unsafe { &Signal[T](sig) }
	s.unsubscribe(e)
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

// --- effects: closure-free (codegen target) ---------------------------------

// effect_ctx runs `action(ctx)` immediately, tracking the signals it reads, and
// re-runs it whenever any of them changes. `action` is a top-level fn and `ctx`
// its context — closure-free, so it runs on wasm. Use effect_handle_ctx to get a
// disposable handle.
pub fn effect_ctx(action fn (ctx voidptr), ctx voidptr) {
	mut e := &Effect{
		action: action
		ctx:    ctx
	}
	run_tracked(mut e)
}

// effect_handle_ctx is effect_ctx that returns the &Effect, so an owner (a
// component instance) can dispose it on unmount — see (mut Effect) dispose.
pub fn effect_handle_ctx(action fn (ctx voidptr), ctx voidptr) &Effect {
	mut e := &Effect{
		action: action
		ctx:    ctx
	}
	run_tracked(mut e)
	return e
}

// --- effects: closure convenience (NATIVE only — boxes a closure) -----------

// effect runs `f` immediately, tracking the signals it reads, and re-runs it on
// change. ERGONOMIC NATIVE FORM: `f` may capture, so it is NOT wasm-portable
// (a captured closure traps on wasm — see the module doc). Codegen emits
// effect_ctx instead; use this for hand-written components/tests/SSR.
pub fn effect(f fn ()) {
	mut box := &ClosureBox{
		f: f
	}
	mut e := &Effect{
		action: run_closure_box
		ctx:    voidptr(box)
		box:    box
	}
	run_tracked(mut e)
}

// effect_handle is effect() that returns the &Effect for disposal. Same native-only
// caveat as effect().
pub fn effect_handle(f fn ()) &Effect {
	mut box := &ClosureBox{
		f: f
	}
	mut e := &Effect{
		action: run_closure_box
		ctx:    voidptr(box)
		box:    box
	}
	run_tracked(mut e)
	return e
}

// run_closure_box is the top-level action that runs a boxed closure.
fn run_closure_box(ctx voidptr) {
	b := unsafe { &ClosureBox(ctx) }
	b.f()
}

// run_tracked detaches `e` from its previous dependencies, then runs it as the
// active effect so its reads re-subscribe it — dynamic dependency tracking.
fn run_tracked(mut e Effect) {
	if e.disposed {
		return
	}
	for c in e.cleanups {
		c.detach(c.sig, e)
	}
	e.cleanups = []
	vcsr_effect_stack << e
	e.action(e.ctx)
	vcsr_effect_stack.pop()
}

// dispose detaches the effect from every signal it reads and stops it re-running.
// A component instance disposes its slot effects on unmount (see runtime.dispose).
pub fn (mut e Effect) dispose() {
	for c in e.cleanups {
		c.detach(c.sig, e)
	}
	e.cleanups = []
	e.disposed = true
}
