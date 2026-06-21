module main

// A closure-FREE reactive counter that compiles to browser-ABI wasm via Path 2
// (v -cc clang + wasi-sdk) and RUNS — proving the path Gate 1 needs.
//
// WHY THIS SHAPE. V's capturing closures (`fn [x] () {...}`) are implemented with
// runtime-generated EXECUTABLE MEMORY (mprotect/exec pages, see
// vlib/builtin/closure/closure_nix.c.v). wasm forbids runtime code generation, so
// a captured closure VALIDATES but TRAPS at call time ("table index is out of
// bounds"). The stock vcsr runtime (signal.v effects, every runtime.bind_* getter
// /handler) is built on capturing closures, so it cannot run in wasm as-is — even
// though it compiles and validates. See docs/WEB-API-SUPPORT.md (Gate 1) and the
// corrected docs/WASM-PATHS-ANALYSIS.md §2.1.
//
// The fix, demonstrated here: model an effect as a TOP-LEVEL function + a context
// pointer instead of a capturing closure. A top-level fn lowers to a plain
// function-table index (an ordinary `call_indirect`), which works on wasm. This
// is the exact transformation signal.v + runtime.v must undergo.
//
// Build + run: see build.sh and harness.mjs (and README.md).

#include "host.h"

// Imported host op: write (ptr,len) text into the mounted DOM node. Becomes
// `(import "env" "host_set_text" (func (param i32 i32)))` — the same (ptr,len)
// boundary the runtime's set_text uses. In a browser the host does
// `node.textContent = str`; in the harness it just records the string.
fn C.host_set_text(ptr &u8, len int)

// --- closure-free reactive core (the pattern signal.v must adopt) -----------

// Effect: a top-level fn + its context — NOT a capturing closure.
@[heap]
struct Effect {
mut:
	run fn (voidptr) = unsafe { nil }
	ctx voidptr
}

__global (
	cur_effect &Effect // the effect currently running (subscription target)
)

// Signal: a value + the effects that read it (its subscribers).
struct Signal {
mut:
	val  int
	subs []&Effect
}

// get reads the value and subscribes the running effect (deduped), mirroring
// signal.v's get().
fn (mut s Signal) get() int {
	if !isnil(cur_effect) {
		mut seen := false
		for x in s.subs {
			if voidptr(x) == voidptr(cur_effect) {
				seen = true
				break
			}
		}
		if !seen {
			s.subs << cur_effect
		}
	}
	return s.val
}

// set writes the value and re-runs every subscriber (over a clone, so a re-run
// that re-subscribes can't extend the loop) — mirroring signal.v's set().
fn (mut s Signal) set(v int) {
	s.val = v
	for e in s.subs.clone() {
		run_effect(e)
	}
}

// run_effect runs `e` as the active effect so its reads subscribe it. The call
// `e.run(e.ctx)` is an indirect call to a TOP-LEVEL fn — a table index, no exec
// thunk — which is why this runs on wasm where a captured closure would trap.
fn run_effect(e &Effect) {
	prev := cur_effect
	cur_effect = e
	e.run(e.ctx)
	cur_effect = prev
}

// --- the "component": reactive state reached via a context pointer ----------

@[heap]
struct Counter {
mut:
	count Signal
}

__global (
	app &Counter
)

// render_count is the effect body — a TOP-LEVEL fn (no captures). `ctx` is the
// Counter; reading the signal subscribes this effect, then it drives the host.
fn render_count(ctx voidptr) {
	mut c := unsafe { &Counter(ctx) }
	s := c.count.get().str()
	C.host_set_text(s.str, s.len)
}

// boot mounts the app: build the Counter, register the render effect, run it once
// (initial render → host_set_text("0")).
@[export: 'boot']
pub fn boot() {
	mut c := &Counter{
		count: Signal{
			val: 0
		}
	}
	app = c
	mut e := &Effect{
		run: render_count
		ctx: c
	}
	run_effect(e)
}

// inc is the event entry point (what a click handler would call): bump the signal;
// every subscribed effect re-runs → host_set_text("N").
@[export: 'inc']
pub fn inc() {
	mut c := app
	c.count.set(c.count.val + 1)
}
