;; route_reports.wat — a lazy-route SIDE module that satisfies the vcsr WASM ABI.
;;
;; Like core.wat, this is hand-written wasm, NOT V output — the proof that the
;; chunk contract is language-neutral. It is the "route-reports.wasm" of the
;; phase-06/07 plan: a position-independent SIDE module that IMPORTS the shared
;; world from core and carries only its own route.
;;
;; Conformance (see docs/WASM-ABI.md + tests/phase_07_wasm_linking_test.v):
;;   - kind = SIDE: IMPORTS core's memory, __indirect_function_table,
;;     __memory_base, __table_base, and the allocator __v_alloc.
;;   - does NOT redefine the runtime/allocator (no __v_alloc of its own).
;;   - EXPORTS the same uniform route interface: mount / unmount.
;;   - position-independent: its data segment is placed relative to
;;     __memory_base (so the loader can relocate it into a free region of the
;;     shared memory).
;;   - DOM crosses as externref.
;;
;; Recompile with:  wat2wasm route_reports.wat -o route_reports.wasm

(module $route_reports
  ;; --- the shared world, IMPORTED from core (Emscripten SIDE_MODULE contract) ---
  (import "core" "memory" (memory 0))
  (import "core" "__indirect_function_table" (table 0 funcref))
  (import "core" "__memory_base" (global $__memory_base i32))
  (import "core" "__table_base" (global $__table_base i32))
  ;; the allocator is IMPORTED, never duplicated into the chunk
  (import "core" "__v_alloc" (func $alloc (param i32) (result i32)))

  ;; host DOM op: set text on a node — the node crosses as externref, the text
  ;; as (ptr,len) into the shared linear memory.
  (import "env" "set_text" (func $set_text (param externref i32 i32)))

  ;; route-local skeleton, placed RELATIVE TO __memory_base => position-independent
  (data (global.get $__memory_base) "<section class=\"reports_x1\"><h2></h2></section>")

  ;; uniform route interface, identical to core's
  (func (export "mount") (param $root externref) (result i32)
    ;; allocate this instance's record via the SHARED allocator
    (call $alloc (i32.const 24)))

  (func (export "unmount") (param $inst i32)))
