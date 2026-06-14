(module
  ;; --- host (JS) imports = the js FFI substrate a browser would provide ---
  (import "env" "log"         (func $log         (param i32 i32)))
  (import "env" "fetch_start" (func $fetch_start (param i32 i32 i32)))      ;; urlptr urllen cbIdx  (ASYNC, returns immediately)
  (import "env" "ls_set"      (func $ls_set      (param i32 i32 i32 i32)))  ;; keyptr keylen valptr vallen  (SYNC)
  (import "env" "ls_get"      (func $ls_get      (param i32 i32 i32) (result i32))) ;; keyptr keylen outptr -> len

  (memory (export "memory") 1)
  (table  (export "__indirect_function_table") 4 funcref)
  (global $result (mut i32) (i32.const 0))

  ;; localStorage key/value, embedded in the data segment
  (data (i32.const 64) "theme")
  (data (i32.const 72) "dark")

  ;; the callback the HOST invokes (via the shared table) when the fetch resolves
  (func $on_response (param $reqid i32) (param $bodyptr i32) (param $bodylen i32)
    (global.set $result (local.get $bodylen))
    (call $log (local.get $bodyptr) (local.get $bodylen)))
  (elem (i32.const 1) $on_response)             ;; register on_response at table index 1

  ;; sync demo: store then read back from localStorage
  (func (export "ls_demo") (result i32)
    (call $ls_set (i32.const 64) (i32.const 5) (i32.const 72) (i32.const 4))
    (call $ls_get (i32.const 64) (i32.const 5) (i32.const 2048)))

  ;; async demo: kick off fetch (host wrote the URL at offset 16), pass cb table idx 1.
  ;; returns IMMEDIATELY — no JSPI, no blocking.
  (func (export "start") (param $urllen i32)
    (call $fetch_start (i32.const 16) (local.get $urllen) (i32.const 1)))

  (func (export "result") (result i32) (global.get $result)))
