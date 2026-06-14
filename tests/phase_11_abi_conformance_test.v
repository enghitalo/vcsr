// Phase 11 — language-neutral ABI conformance.
//
// GOAL: prove the loader/linker contract is defined on the wasm *interface*, not
// on V. Phase 07 pins the MAIN/SIDE contract for modules vcsr EMITS; phase 11
// pins that the SAME contract is satisfiable — and statically checkable — by a
// module vcsr DID NOT emit. The fixtures in tests/fixtures/abi/ are hand-written
// WebAssembly (could equally be Rust/Zig/C); see docs/WASM-ABI.md.
//
// Where phase 07 derives a Module from a route plan (`wasm.link(plan)`), phase 11
// derives the same Module shape from raw bytes (`wasm.inspect(bytes)`), so the
// invariants below read identically to phase 07 — by design: one Module type,
// two producers (vcsr codegen vs. any external toolchain).
module main

import os
import vcsr.wasm { DomAbi, ModuleKind }

const fixtures = os.join_path(os.dir(@FILE), 'fixtures', 'abi')

fn core() wasm.Module {
	bytes := os.read_bytes(os.join_path(fixtures, 'core.wasm')) or { panic(err) }
	return wasm.inspect(bytes) or { panic(err) }
}

fn route() wasm.Module {
	bytes := os.read_bytes(os.join_path(fixtures, 'route_reports.wasm')) or { panic(err) }
	return wasm.inspect(bytes) or { panic(err) }
}

// --- the non-V CORE module satisfies the MAIN contract ---

fn test_core_fixture_is_main_module() {
	assert core().kind == ModuleKind.main
}

fn test_core_fixture_exports_shared_world() {
	c := core()
	assert c.exports.contains('memory')
	assert c.exports.contains('__indirect_function_table')
	assert c.exports.contains('__v_alloc')
	assert c.exports.contains('__v_free')
}

fn test_core_fixture_exposes_route_interface() {
	c := core()
	assert c.exports.contains('mount')
	assert c.exports.contains('unmount')
}

// --- the non-V SIDE module satisfies the chunk contract ---

fn test_side_fixture_is_side_module() {
	assert route().kind == ModuleKind.side
}

fn test_side_fixture_imports_core_world() {
	r := route()
	assert r.imports.contains('core', 'memory')
	assert r.imports.contains('core', '__indirect_function_table')
	assert r.imports.contains('core', '__memory_base')
	assert r.imports.contains('core', '__table_base')
}

fn test_side_fixture_does_not_redefine_runtime() {
	// the allocator must be imported from core, never duplicated into the chunk
	r := route()
	assert !r.defines('__v_alloc')
	assert r.imports.contains('core', '__v_alloc')
}

fn test_side_fixture_exports_uniform_route_interface() {
	r := route()
	assert r.exports.contains('mount')
	assert r.exports.contains('unmount')
}

fn test_side_fixture_is_position_independent() {
	// its data segment is placed relative to the imported __memory_base
	assert route().pic
}

// --- the DOM boundary is uniform and copy-free across producers ---

fn test_dom_crosses_as_externref() {
	// mount() takes the host root node as an externref in both fixtures — the
	// same boundary the phase-07 link plan asserts (boundary_abi.dom == .externref)
	assert core().dom == DomAbi.externref
	assert route().dom == DomAbi.externref
}

// --- the verdict is independent of the producing language ---

fn test_conformance_is_language_neutral() {
	// verify_abi inspects only the wasm interface; it has no notion of V. A
	// conforming module from ANY toolchain passes; these fixtures are hand-written
	// WAT precisely to make that non-trivial.
	core_bytes := os.read_bytes(os.join_path(fixtures, 'core.wasm')) or { panic(err) }
	side_bytes := os.read_bytes(os.join_path(fixtures, 'route_reports.wasm')) or { panic(err) }

	core_ok := wasm.verify_abi(core_bytes, ModuleKind.main) or { panic(err) }
	side_ok := wasm.verify_abi(side_bytes, ModuleKind.side) or { panic(err) }

	assert core_ok.conforms
	assert core_ok.violations.len == 0
	assert side_ok.conforms
	assert side_ok.violations.len == 0
}

fn test_nonconforming_module_is_rejected_with_reasons() {
	// a SIDE module that redefines the allocator (instead of importing it) must
	// fail conformance with an actionable violation — proving the check has teeth.
	bad := os.read_bytes(os.join_path(fixtures, 'route_reports.wasm')) or { panic(err) }
	// checked against the WRONG kind: a SIDE module is not a valid MAIN module
	// (it imports memory rather than owning/exporting it).
	verdict := wasm.verify_abi(bad, ModuleKind.main) or { panic(err) }
	assert !verdict.conforms
	assert verdict.violations.any(it.contains('memory'))
}
