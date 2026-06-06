// Phase 07 — WASM emission + shared-memory linking.
//
// GOAL: emit core.wasm as a MAIN module that owns and exports the memory, the
// indirect function table, the allocator, and the runtime/shared components;
// emit each lazy route as a SIDE module that IMPORTS them (position-independent,
// relocated at load). No duplicated runtime in chunks; a closure created in a
// chunk lands in the shared table so core can call it; DOM values cross as
// externref.
//
// Precedent: Emscripten MAIN_MODULE/SIDE_MODULE + dlopen.
// See ../../v-web-csr-concept/SCALING.md ("The shared-memory contract").
module main

import vcsr.router { Route }
import vcsr.wasm { ModuleKind }

fn linked() wasm.LinkPlan {
	plan := router.plan([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/reports', component: 'Reports', lazy: true },
	]) or { panic(err) }
	return wasm.link(plan) or { panic(err) }
}

fn test_core_is_main_module() {
	core := linked().core
	assert core.kind == ModuleKind.main
}

fn test_core_exports_shared_world() {
	core := linked().core
	assert core.exports.contains('memory')
	assert core.exports.contains('__indirect_function_table')
	assert core.exports.contains('__v_alloc')
	assert core.exports.contains('__v_free')
}

fn test_route_chunk_is_side_module() {
	chunk := linked().chunk('reports')
	assert chunk.kind == ModuleKind.side
}

fn test_chunk_imports_core_memory_and_table() {
	chunk := linked().chunk('reports')
	assert chunk.imports.contains('core', 'memory')
	assert chunk.imports.contains('core', '__indirect_function_table')
	assert chunk.imports.contains('core', '__memory_base')
	assert chunk.imports.contains('core', '__table_base')
}

fn test_chunk_does_not_redefine_runtime() {
	// the runtime/allocator must be imported, never duplicated into a chunk
	chunk := linked().chunk('reports')
	assert !chunk.defines('__v_alloc')
	assert chunk.imports.contains('core', '__v_alloc')
}

fn test_chunk_exports_uniform_route_interface() {
	chunk := linked().chunk('reports')
	assert chunk.exports.contains('mount')
	assert chunk.exports.contains('unmount')
}

fn test_chunk_is_position_independent() {
	chunk := linked().chunk('reports')
	assert chunk.pic // relocatable: data/funcs relative to __memory_base/__table_base
}

fn test_relocation_bases_are_disjoint_per_chunk() {
	// two chunks must be assigned non-overlapping memory/table regions
	plan := router.plan([
		Route{ path: '/', component: 'Home' },
		Route{ path: '/a', component: 'A', lazy: true },
		Route{ path: '/b', component: 'B', lazy: true },
	]) or { panic(err) }
	lp := wasm.link(plan) or { panic(err) }
	a := lp.chunk('a').reloc
	b := lp.chunk('b').reloc
	assert a.mem_range.end <= b.mem_range.start || b.mem_range.end <= a.mem_range.start
	assert a.table_range.end <= b.table_range.start || b.table_range.end <= a.table_range.start
}

fn test_closure_from_chunk_uses_shared_table() {
	// an event handler defined in a chunk must be callable by core → shared table
	chunk := linked().chunk('reports')
	assert chunk.closures_use_shared_table
}

fn test_dom_values_cross_as_externref() {
	// passing a DOM node between core and chunk must not require linear-memory copy
	lp := linked()
	assert lp.boundary_abi.dom == .externref
}
