// Phase 07 + 11 — the WASM module: ONE `Module` type, two producers.
//
// vcsr is two separable things: a frontend that compiles a V component triplet
// to WASM, and a runtime *contract* — what a module exports/imports and how DOM
// values cross the boundary. This module owns the second thing in both
// directions:
//
//   (A) LINK PLANNER (phase 07): from a phase-06 `router.Plan` we derive the
//       MAIN/SIDE link plan vcsr would EMIT — core.wasm owns and exports the
//       shared world (memory, table, allocator), each lazy route is a
//       position-independent SIDE chunk that imports it and is relocated into a
//       disjoint region of the shared memory/table. Pure data; no real bytes.
//
//   (B) BINARY INSPECTOR (phase 11): from RAW wasm bytes we derive the SAME
//       `Module` shape, proving the contract is defined on the wasm interface
//       (not on V) and is statically checkable for a module vcsr did NOT emit.
//
// The contract is mirrored from Emscripten MAIN_MODULE / SIDE_MODULE + dlopen.
// See ../docs/WASM-ABI.md and ../docs/SCALING.md.
module wasm

import vcsr.router

// --- shared vocabulary ------------------------------------------------------

// ModuleKind distinguishes the one MAIN module (owns + exports the shared
// world) from each SIDE chunk (imports it; one per lazy route).
pub enum ModuleKind {
	main
	side
}

// DomAbi is how an opaque host handle (a DOM node, a callback) crosses the
// wasm↔host boundary. `.externref` is a first-class reference value that never
// touches linear memory and is uniform across producers (the target); the
// integer `.handle_table` is the documented bridge for toolchains that can't
// emit externref yet. See docs/WASM-ABI.md §"The DOM boundary".
pub enum DomAbi {
	externref
	handle_table
}

// Range is a half-open `[start, end)` region — used for a chunk's relocation
// window in the shared memory and table.
pub struct Range {
pub:
	start int
	end   int
}

// Reloc is where the loader places a position-independent chunk: a disjoint
// slice of the shared linear memory (`mem_range`, the `__memory_base` window)
// and of the shared call table (`table_range`, the `__table_base` window).
pub struct Reloc {
pub:
	mem_range   Range
	table_range Range
}

// Sym is one export: its name, whether its signature touches externref, and —
// for function exports — its index in the function index space (-1 for
// non-function exports). The index is only used transiently by the inspector to
// resolve the externref flag once the whole index space is known.
struct Sym {
	name          string
	func_index    int = -1
	uses_externref bool
}

// Symbols is a module's export set, with name lookup.
pub struct Symbols {
mut:
	syms []Sym
}

// contains reports whether the module exports `name`.
pub fn (s &Symbols) contains(name string) bool {
	for sym in s.syms {
		if sym.name == name {
			return true
		}
	}
	return false
}

// Imp is one import: namespace, name, whether it is a function import (so it
// occupies a slot in the function index space), and whether its signature
// touches externref.
struct Imp {
	ns            string
	name          string
	is_func       bool
	uses_externref bool
}

// ImportSet is a module's import set, with (namespace, name) lookup.
pub struct ImportSet {
mut:
	imps []Imp
}

// contains reports whether the module imports `name` from namespace `ns`.
pub fn (s &ImportSet) contains(ns string, name string) bool {
	for imp in s.imps {
		if imp.ns == ns && imp.name == name {
			return true
		}
	}
	return false
}

// --- the one Module type (planner + inspector both produce it) --------------

// Module is the wasm interface of one bundle, as seen by the loader/linker.
// Both `link` (from a route plan) and `inspect` (from raw bytes) produce it, so
// the phase-07 and phase-11 invariants read identically.
pub struct Module {
pub:
	kind                    ModuleKind
	exports                 Symbols
	imports                 ImportSet
	pic                     bool // position-independent (relative to __memory_base/__table_base)
	closures_use_shared_table bool // a closure made here lands in the shared table
	dom                     DomAbi
	reloc                   Reloc
}

// defines reports whether the module provides `name` itself (exports it without
// importing it) — the test that a SIDE chunk does NOT redefine the runtime.
pub fn (m &Module) defines(name string) bool {
	if m.imports.contains_name(name) {
		return false
	}
	return m.exports.contains(name)
}

// contains_name reports whether any import (in any namespace) has this name.
fn (s &ImportSet) contains_name(name string) bool {
	for imp in s.imps {
		if imp.name == name {
			return true
		}
	}
	return false
}

// --- (A) the link planner: route plan → MAIN/SIDE link plan -----------------

// BoundaryAbi captures how cross-module/host values travel. vcsr's link plan
// targets `externref` for DOM (the fixtures and spec agree).
pub struct BoundaryAbi {
pub:
	dom DomAbi
}

// LinkPlan is the whole linked bundle: the one MAIN `core` module plus the
// per-route SIDE chunks, and the boundary ABI they all share.
pub struct LinkPlan {
pub:
	core         Module
	boundary_abi BoundaryAbi
mut:
	chunks map[string]Module
}

// chunk returns the named SIDE module (a lazy route's chunk), or a zero Module
// if absent.
pub fn (lp &LinkPlan) chunk(name string) Module {
	return lp.chunks[name] or { Module{} }
}

// link lays out the MAIN/SIDE link plan for a route plan: core.wasm owns and
// exports the shared world and the landing route; each lazy route becomes a
// position-independent SIDE chunk that imports that world and is relocated into
// a disjoint slice of the shared memory and table.
pub fn link(plan router.Plan) !LinkPlan {
	core := Module{
		kind: .main
		exports: Symbols{
			syms: [
				// the shared world this MAIN module owns and hands to side modules
				Sym{ name: 'memory' },
				Sym{ name: '__indirect_function_table' },
				Sym{ name: '__v_alloc' },
				Sym{ name: '__v_free' },
				// the landing route lives in core; mount takes the host root as externref
				Sym{ name: 'mount', uses_externref: true },
				Sym{ name: 'unmount' },
			]
		}
		imports: ImportSet{
			imps: [
				// host DOM ops: values cross as externref
				Imp{ ns: 'env', name: 'register_template', uses_externref: true },
				Imp{ ns: 'env', name: 'clone_template', uses_externref: true },
			]
		}
		pic: false // the MAIN module owns absolute memory/table; only chunks relocate
		closures_use_shared_table: true
		dom: .externref
	}

	// each lazy route → one SIDE chunk, assigned a disjoint relocation window.
	mut chunks := map[string]Module{}
	mut names := lazy_chunk_names(plan)
	for i, name in names {
		chunks[name] = side_chunk(i)
	}

	return LinkPlan{
		core: core
		boundary_abi: BoundaryAbi{ dom: .externref }
		chunks: chunks
	}
}

// per-chunk relocation windows: each SIDE chunk gets one wasm page of the
// shared linear memory and a fixed band of the shared table, so two chunks
// never collide.
const chunk_mem_window = 65536 // one wasm page per chunk's data window
const chunk_table_window = 256 // table slots reserved per chunk

// side_chunk builds the SIDE module for the `idx`-th lazy route: it imports the
// shared world from core (never redefining the runtime), exports the uniform
// route interface, is position-independent, and is relocated into the disjoint
// `[idx*W, idx*W+W)` slice of the shared memory and table.
fn side_chunk(idx int) Module {
	mem_start := idx * chunk_mem_window
	tbl_start := idx * chunk_table_window
	return Module{
		kind: .side
		imports: ImportSet{
			imps: [
				// the shared world, IMPORTED from core (SIDE_MODULE contract)
				Imp{ ns: 'core', name: 'memory' },
				Imp{ ns: 'core', name: '__indirect_function_table' },
				Imp{ ns: 'core', name: '__memory_base' }, // relocation base for data
				Imp{ ns: 'core', name: '__table_base' },  // relocation base for funcs
				// the allocator is IMPORTED, never duplicated into the chunk
				Imp{ ns: 'core', name: '__v_alloc' },
				// host DOM op: the node crosses as externref
				Imp{ ns: 'env', name: 'set_text', uses_externref: true },
			]
		}
		exports: Symbols{
			syms: [
				// uniform route interface, identical to core's
				Sym{ name: 'mount', uses_externref: true },
				Sym{ name: 'unmount' },
			]
		}
		pic: true // data/funcs placed relative to __memory_base/__table_base
		closures_use_shared_table: true
		dom: .externref
		reloc: Reloc{
			mem_range:   Range{ start: mem_start, end: mem_start + chunk_mem_window }
			table_range: Range{ start: tbl_start, end: tbl_start + chunk_table_window }
		}
	}
}

// lazy_chunk_names returns the lazy routes' chunk names in route-table order
// (the last non-empty path segment, matching router.chunk_name), each once.
fn lazy_chunk_names(plan router.Plan) []string {
	mut out := []string{}
	for r in plan.routes {
		if !r.lazy {
			continue
		}
		name := last_segment(r.path)
		if name != '' && name !in out {
			out << name
		}
	}
	return out
}

fn last_segment(path string) string {
	segs := path.split('/').filter(it != '')
	if segs.len == 0 {
		return ''
	}
	return segs[segs.len - 1]
}

// --- (B) the binary inspector: raw wasm bytes → the same Module --------------

// section ids in the WebAssembly binary format we care about.
const sec_type = u8(1)
const sec_import = u8(2)
const sec_function = u8(3)
const sec_export = u8(7)

// import/export descriptor kinds (the byte after the name).
const kind_func = u8(0x00)
const kind_table = u8(0x01)
const kind_mem = u8(0x02)
const kind_global = u8(0x03)

// the externref value type in a function signature.
const valtype_externref = u8(0x6f)

// a parsed function type: does its signature mention externref?
struct FuncType {
	uses_externref bool
}

// inspect parses a WebAssembly binary into the same `Module` shape the linker
// produces. It reads the TYPE, IMPORT and EXPORT sections, classifies the
// module as MAIN (exports a memory) or SIDE (imports a memory), and marks the
// DOM ABI as `.externref` whenever an imported/exported function signature uses
// externref. `pic` is true for a SIDE module that imports `__memory_base`.
pub fn inspect(bytes []u8) !Module {
	mut r := Reader{ b: bytes }
	r.expect_header()!

	mut types := []FuncType{}
	mut exports := []Sym{}
	mut imports := []Imp{}
	mut exports_mem := false
	mut imports_mem := false
	mut imports_memory_base := false
	mut uses_externref := false

	// the FUNCTION section (id 3) maps each defined function to its type index;
	// combined with the imported-func types it gives every function's signature.
	mut func_type_idx := []int{}
	mut imported_func_ext := []bool{}

	for !r.at_end() {
		id := r.u8()!
		size := r.uleb()!
		body := r.take(size)!
		match id {
			sec_type {
				types = parse_type_section(body)!
				// any externref anywhere in a signature ⇒ the DOM boundary is externref.
				for t in types {
					if t.uses_externref {
						uses_externref = true
					}
				}
			}
			sec_function {
				func_type_idx = parse_function_section(body)!
			}
			sec_import {
				imps, im, imb, ife := parse_import_section(body, types)!
				imports = imps.clone()
				imports_mem = im
				imports_memory_base = imb
				imported_func_ext = ife.clone()
			}
			sec_export {
				exps, em := parse_export_section(body)!
				exports = exps.clone()
				exports_mem = em
			}
			else {} // table/memory/global/code/data: not needed for the interface
		}
	}

	// resolve each function export's externref flag through the full function
	// index space (imported funcs first, then defined funcs by FUNCTION section).
	exports = resolve_export_externref(exports, imported_func_ext, func_type_idx, types)

	kind := if exports_mem {
		ModuleKind.main
	} else if imports_mem {
		ModuleKind.side
	} else {
		return error('module neither exports nor imports a memory: not a conforming MAIN or SIDE module')
	}

	dom := if uses_externref { DomAbi.externref } else { DomAbi.handle_table }

	return Module{
		kind: kind
		exports: Symbols{ syms: exports }
		imports: ImportSet{ imps: imports }
		// a SIDE module that imports __memory_base places its data relative to it.
		pic: kind == .side && imports_memory_base
		closures_use_shared_table: true
		dom: dom
	}
}

// parse_type_section reads the function-type vector, recording for each whether
// any param or result is externref (so we can flag the DOM boundary).
fn parse_type_section(body []u8) ![]FuncType {
	mut r := Reader{ b: body }
	count := r.uleb()!
	mut out := []FuncType{cap: count}
	for _ in 0 .. count {
		form := r.u8()!
		if form != 0x60 {
			return error('type entry is not a func type (0x60), got 0x${form.hex()}')
		}
		mut ext := false
		np := r.uleb()!
		for _ in 0 .. np {
			if r.u8()! == valtype_externref {
				ext = true
			}
		}
		nr := r.uleb()!
		for _ in 0 .. nr {
			if r.u8()! == valtype_externref {
				ext = true
			}
		}
		out << FuncType{ uses_externref: ext }
	}
	return out
}

// parse_import_section reads the import vector. Returns the imports, whether a
// memory is imported, whether `__memory_base` is imported (the pic signal), and
// the externref flag of each IMPORTED FUNCTION in order — imported functions
// hold the low slots of the function index space, ahead of defined functions.
fn parse_import_section(body []u8, types []FuncType) !([]Imp, bool, bool, []bool) {
	mut r := Reader{ b: body }
	count := r.uleb()!
	mut out := []Imp{cap: count}
	mut imported_func_ext := []bool{}
	mut has_mem := false
	mut has_memory_base := false
	for _ in 0 .. count {
		ns := r.name()!
		name := r.name()!
		kind := r.u8()!
		mut is_func := false
		mut ext := false
		match kind {
			kind_func {
				is_func = true
				tidx := r.uleb()!
				if tidx >= types.len {
					return error('import "${ns}.${name}" references type index ${tidx} out of range')
				}
				ext = types[tidx].uses_externref
				imported_func_ext << ext
			}
			kind_table {
				r.skip_table_type()!
			}
			kind_mem {
				r.skip_limits()!
				if name == 'memory' {
					has_mem = true
				}
			}
			kind_global {
				r.u8()! // value type
				r.u8()! // mutability
			}
			else {
				return error('unknown import descriptor kind 0x${kind.hex()}')
			}
		}
		if name == '__memory_base' {
			has_memory_base = true
		}
		out << Imp{ ns: ns, name: name, is_func: is_func, uses_externref: ext }
	}
	return out, has_mem, has_memory_base, imported_func_ext
}

// parse_function_section reads the FUNCTION section: the type index of each
// locally-defined function, in definition order.
fn parse_function_section(body []u8) ![]int {
	mut r := Reader{ b: body }
	count := r.uleb()!
	mut out := []int{cap: count}
	for _ in 0 .. count {
		out << r.uleb()!
	}
	return out
}

// parse_export_section reads the export vector, recording each export's name,
// descriptor kind and index, and whether any memory is exported. The externref
// flag is filled in later, once the whole function index space is known.
fn parse_export_section(body []u8) !([]Sym, bool) {
	mut r := Reader{ b: body }
	count := r.uleb()!
	mut out := []Sym{cap: count}
	mut has_mem := false
	for _ in 0 .. count {
		name := r.name()!
		kind := r.u8()!
		idx := r.uleb()!
		// stash the function index in `uses_externref` resolution metadata by
		// carrying it through a temporary Sym; the real flag is set in
		// resolve_export_externref. We keep idx via a parallel encoding: only
		// function exports need it, so record kind by leaving non-funcs at idx -1.
		out << Sym{
			name:           name
			func_index:     if kind == kind_func { idx } else { -1 }
			uses_externref: false
		}
		if kind == kind_mem && name == 'memory' {
			has_mem = true
		}
	}
	return out, has_mem
}

// resolve_export_externref fills in each function export's externref flag by
// mapping its function index through the full index space: imported functions
// (their types in `imported_func_ext`) come first, then defined functions
// (`func_type_idx` → `types`). Non-function exports are returned unchanged.
fn resolve_export_externref(exports []Sym, imported_func_ext []bool, func_type_idx []int, types []FuncType) []Sym {
	mut out := []Sym{cap: exports.len}
	imported := imported_func_ext.len
	for e in exports {
		if e.func_index < 0 {
			out << e
			continue
		}
		fi := e.func_index
		mut ext := false
		if fi < imported {
			ext = imported_func_ext[fi]
		} else {
			defined_i := fi - imported
			if defined_i < func_type_idx.len {
				tidx := func_type_idx[defined_i]
				if tidx >= 0 && tidx < types.len {
					ext = types[tidx].uses_externref
				}
			}
		}
		out << Sym{ name: e.name, func_index: e.func_index, uses_externref: ext }
	}
	return out
}

// --- conformance ------------------------------------------------------------

// Conformance is the verdict of `verify_abi`: does the module satisfy the
// MAIN/SIDE contract for the requested kind, and if not, why.
pub struct Conformance {
pub:
	conforms   bool
	violations []string
}

// verify_abi statically checks a wasm module's interface against the
// MAIN/SIDE contract for `kind` (docs/WASM-ABI.md). It inspects only the wasm
// interface — it has no notion of V — so a conforming module from any toolchain
// passes. A SIDE module checked as MAIN fails (it imports memory instead of
// owning/exporting it), with an actionable violation.
pub fn verify_abi(bytes []u8, kind ModuleKind) !Conformance {
	m := inspect(bytes)!
	mut violations := []string{}

	match kind {
		.main {
			// MAIN owns and exports the shared world + the route interface.
			if m.kind != .main {
				violations << 'expected a MAIN module that exports its own memory, but this module imports memory from another module'
			}
			for need in ['memory', '__indirect_function_table', '__v_alloc', '__v_free',
				'mount', 'unmount'] {
				if !m.exports.contains(need) {
					violations << 'MAIN module must export "${need}"'
				}
			}
		}
		.side {
			// SIDE imports the shared world and exports only the route interface.
			if m.kind != .side {
				violations << 'expected a SIDE module that imports memory from core, but this module exports its own memory'
			}
			for need in ['memory', '__indirect_function_table', '__memory_base',
				'__table_base', '__v_alloc'] {
				if !m.imports.contains('core', need) {
					violations << 'SIDE module must import core.${need}'
				}
			}
			// the allocator must be imported, never redefined.
			if m.defines('__v_alloc') {
				violations << 'SIDE module must not redefine "__v_alloc"; import it from core'
			}
			for need in ['mount', 'unmount'] {
				if !m.exports.contains(need) {
					violations << 'SIDE module must export "${need}"'
				}
			}
		}
	}

	return Conformance{
		conforms:   violations.len == 0
		violations: violations
	}
}

// --- a tiny zero-copy wasm byte reader --------------------------------------

// Reader walks a wasm byte slice with a cursor; all reads are bounds-checked
// and error rather than panic, so malformed input is a build error.
struct Reader {
	b []u8
mut:
	pos int
}

fn (mut r Reader) at_end() bool {
	return r.pos >= r.b.len
}

fn (mut r Reader) u8() !u8 {
	if r.pos >= r.b.len {
		return error('unexpected end of wasm bytes')
	}
	v := r.b[r.pos]
	r.pos++
	return v
}

// expect_header consumes the `\0asm` magic and the version word (must be 1).
fn (mut r Reader) expect_header() ! {
	if r.b.len < 8 {
		return error('too short to be a wasm module')
	}
	if r.b[0] != 0x00 || r.b[1] != 0x61 || r.b[2] != 0x73 || r.b[3] != 0x6d {
		return error('bad wasm magic: not a WebAssembly binary')
	}
	if r.b[4] != 0x01 || r.b[5] != 0x00 || r.b[6] != 0x00 || r.b[7] != 0x00 {
		return error('unsupported wasm version (expected 1)')
	}
	r.pos = 8
}

// uleb reads an unsigned LEB128 integer.
fn (mut r Reader) uleb() !int {
	mut result := u32(0)
	mut shift := u32(0)
	for {
		byte_val := r.u8()!
		result |= u32(byte_val & 0x7f) << shift
		if byte_val & 0x80 == 0 {
			break
		}
		shift += 7
		if shift >= 35 {
			return error('LEB128 integer too long')
		}
	}
	return int(result)
}

// take returns the next `n` bytes as a sub-slice and advances the cursor.
fn (mut r Reader) take(n int) ![]u8 {
	if n < 0 || r.pos + n > r.b.len {
		return error('section length runs past end of wasm bytes')
	}
	out := r.b[r.pos..r.pos + n]
	r.pos += n
	return out
}

// name reads a length-prefixed UTF-8 name (a wasm "name": uleb len + bytes).
fn (mut r Reader) name() !string {
	n := r.uleb()!
	bytes := r.take(n)!
	return bytes.bytestr()
}

// skip_limits skips a `limits` (flag byte, then min, then optional max).
fn (mut r Reader) skip_limits() ! {
	flags := r.u8()!
	r.uleb()! // min
	if flags & 0x01 != 0 {
		r.uleb()! // max
	}
}

// skip_table_type skips a table type (element reftype byte + limits).
fn (mut r Reader) skip_table_type() ! {
	r.u8()! // element reference type (e.g. 0x70 funcref)
	r.skip_limits()!
}
