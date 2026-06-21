// Phase 04 — Component model: pair the file triplet, resolve refs, EMIT PLAIN V.
//
// A component is three co-located files sharing a basename — `name.v` (logic:
// the @[component] struct + signal fields + handlers), `name.html` (template),
// `name.css` (styles, optional). `analyze` is what vcsr does after reading them
// off disk: it parses the logic file for the struct's name/fields/methods, the
// template (phase 01 → 02 → 03), resolves the template's references against the
// struct, and yields a `Component` IR. `codegen` then emits `name.gen.v` — plain
// V implementing `view()`/`style()` that imports only the vcsr runtime, with NO
// `$vui`/`$css`/`$`-builtins (the "no V compiler changes" rule).
//
// See ../docs/ARCHITECTURE.md and ../docs/COMPONENTS.md.
module component

import strings
import vcsr.ast
import vcsr.parser
import vcsr.slots
import vcsr.bind

// --- public IR --------------------------------------------------------------

// A struct field discovered in the logic file. Signal fields carry their inner
// generic type (`vcsr.Signal[int]` → typ = 'int').
struct Field {
	name      string
	typ       string
	is_signal bool
}

// A signal field, as returned by `Component.signal_field`.
pub struct SignalField {
pub:
	name string
	typ  string
}

// HoistDecision says where a (possibly shared) child component's template lives.
pub enum HoistDecision {
	core        // shared across routes → one copy in core.wasm
	route_local // used by a single route → stays in that route's chunk
}

// Component is the analyzed file triplet: the struct's shape plus the compiled
// template and scoped styles, ready for codegen.
pub struct Component {
pub:
	name      string
	children  []string // PascalCase child-component tags used in the template
	fields    []Field
	methods   []string
	tmpl      slots.CompiledTemplate
	bplan     bind.BindingPlan
	style_src string // scoped CSS to embed in style()
}

// Generated is the emitted `name.gen.v` file.
pub struct Generated {
pub:
	filename              string
	source                string
	compiles_with_stock_v bool
}

// --- analyze ----------------------------------------------------------------

@[params]
pub struct AnalyzeInput {
pub:
	v    string // the logic file (.v): @[component] struct + handlers
	html string // the template file (.html)
	css  string // the styles file (.css), optional
}

// analyze pairs the triplet, resolves the template against the struct, and
// returns the Component IR. An unknown reference/handler, or a missing template,
// is a build error.
pub fn analyze(input AnalyzeInput) !Component {
	name, fields, methods := parse_logic(input.v)!
	if input.html.trim_space() == '' {
		return error('component ${name} has no template (.html)')
	}
	tree := parser.parse_template(input.html)!

	mut children := []string{}
	collect_children(tree.root, mut children)

	tmpl := slots.compile(tree)!
	bplan := bind.plan(tmpl)!

	comp := Component{
		name:      name
		children:  children
		fields:    fields
		methods:   methods
		tmpl:      tmpl
		bplan:     bplan
		style_src: scope_css(name, input.css)
	}
	comp.check_node(tree.root, []string{})!
	return comp
}

// --- struct queries ---------------------------------------------------------

// signal_field returns the named signal field, or an error if absent.
pub fn (c &Component) signal_field(name string) !SignalField {
	for f in c.fields {
		if f.name == name && f.is_signal {
			return SignalField{
				name: f.name
				typ:  f.typ
			}
		}
	}
	return error('no signal field "${name}" in component ${c.name}')
}

// has_method reports whether the struct defines a method named `name`.
pub fn (c &Component) has_method(name string) bool {
	return name in c.methods
}

fn (c &Component) is_signal(name string) bool {
	for f in c.fields {
		if f.name == name && f.is_signal {
			return true
		}
	}
	return false
}

fn (c &Component) is_field(name string) bool {
	for f in c.fields {
		if f.name == name {
			return true
		}
	}
	return false
}

// resolves_ref reports whether a template reference (`{{ name }}`) names a field
// or method of the struct.
pub fn (c &Component) resolves_ref(name string) bool {
	return c.is_field(name) || c.has_method(name)
}

// resolves_handler reports whether an event handler names a method.
pub fn (c &Component) resolves_handler(name string) bool {
	return c.has_method(name)
}

// --- reference resolution (the type-check) ----------------------------------

// check_node walks the AST validating that every reactive expression resolves
// in the component's scope. `locals` carries @for loop variables in scope. Props
// and events FORWARDED to child components are not checked here — they resolve
// against the child's struct (a cross-component concern, see COMPONENTS.md).
fn (c &Component) check_node(node ast.Node, locals []string) ! {
	mut scope := locals.clone()
	if e := node.each {
		c.check_expr(e.source_expr, locals, false)! // source resolves in outer scope
		scope << e.item_name
		if e.key_expr != '' {
			c.check_expr(e.key_expr, scope, false)!
		}
	}
	if cd := node.cond {
		c.check_expr(cd.expr, scope, false)!
	}
	match node.kind {
		.interpolation {
			c.check_expr(node.expr, scope, false)!
		}
		.element {
			for ev in node.events {
				c.check_expr(ev.handler_expr, scope, true)!
			}
			for ab in node.attr_bindings {
				c.check_expr(ab.expr, scope, false)!
			}
			if b := node.binding {
				c.check_expr(b.target_expr, scope, false)!
			}
			for cb in node.class_bindings {
				c.check_expr(cb.expr, scope, false)!
			}
		}
		else {} // .text: nothing; .component: forwarded refs resolved later
	}

	for child in node.children {
		c.check_node(child, scope)!
	}
}

fn (c &Component) check_expr(expr string, scope []string, is_handler bool) ! {
	for id in bind.free_idents(expr) {
		if id in scope || c.resolves_ref(id) {
			continue
		}
		if is_handler {
			return error('unknown handler "${id}" in component ${c.name}')
		}
		return error('unknown reference "${id}" in component ${c.name}')
	}
}

// --- codegen: PLAIN V, no compiler builtins ---------------------------------

// codegen emits `name.gen.v`: plain V implementing view()/style(), importing
// only vcsr.runtime. Contains no `$vui`/`$css`/`$`-builtin of any kind.
pub fn (c &Component) codegen() !Generated {
	recv := c.recv()
	lower := c.name.to_lower()
	mut b := strings.new_builder(512)

	b.write_string('// ${lower}.gen.v — GENERATED by vcsr. Do not edit.\n')
	b.write_string('// Plain V; imports only the vcsr runtime (no compiler builtins).\n')
	b.write_string('module main\n\n')
	b.write_string('import vcsr.runtime\n\n')

	// the static skeleton + slot table, embedded as a plain const
	b.write_string('const __${lower}_tpl = runtime.Template{\n')
	b.write_string("\thtml:  '${esc(c.tmpl.html)}'\n")
	b.write_string('\tslots: [\n')
	for s in c.tmpl.slots {
		b.write_string('\t\truntime.SlotDesc{ kind: .${slot_kind_name(s.kind)}, path: ${render_path(s.path)}')
		if s.name != '' {
			b.write_string(", name: '${esc(s.name)}'")
		}
		b.write_string(' },\n')
	}
	b.write_string('\t]\n')
	b.write_string('}\n\n')

	// per-slot helpers: TOP-LEVEL fns (closure-free, so they run on wasm — see
	// signal.v / docs/WEB-API-SUPPORT.md). Each takes the component as a `voidptr`
	// ctx, casts it back, and evaluates the bound expression.
	for i, s in c.tmpl.slots {
		c.emit_slot_helper(mut b, i, s)
	}

	// view(): clone the template once, wire each slot to the reactive runtime via
	// the closure-free bind_*_ctx API, passing the receiver as the ctx pointer.
	b.write_string('pub fn (mut ${recv} ${c.name}) view() runtime.View {\n')
	b.write_string('\tmut ins := __${lower}_tpl.instance()\n')
	for i, s in c.tmpl.slots {
		c.emit_bind(mut b, recv, i, s)
	}
	b.write_string('\treturn ins.view()\n')
	b.write_string('}\n\n')

	// style(): the component-scoped stylesheet, as a plain string
	b.write_string('pub fn (${recv} ${c.name}) style() string {\n')
	b.write_string("\treturn '${esc(c.style_src)}'\n")
	b.write_string('}\n')

	source := b.str()
	return Generated{
		filename:              '${lower}.gen.v'
		source:                source
		compiles_with_stock_v: !source.contains('\$') // no comptime builtin → stock V compiles it
	}
}

// emit_bind writes one closure-free runtime binding call for slot `i`: the
// receiver is passed as the ctx pointer (`voidptr(&recv)`) and the per-slot
// top-level helper fn (emitted by emit_slot_helper) is referenced by name.
fn (c &Component) emit_bind(mut b strings.Builder, recv string, i int, s slots.SlotDesc) {
	lower := c.name.to_lower()
	ctx := 'voidptr(&${recv})'
	match s.kind {
		.text {
			b.write_string('\truntime.bind_text_ctx(mut ins, ${i}, ${ctx}, ${lower}_slot${i}_get)\n')
		}
		.attr {
			b.write_string("\truntime.bind_attr_ctx(mut ins, ${i}, '${esc(s.name)}', ${ctx}, ${lower}_slot${i}_get)\n")
		}
		.event {
			b.write_string('\truntime.bind_event_ctx(mut ins, ${i}, ${ctx}, ${lower}_slot${i}_evt)\n')
		}
		.bind {
			b.write_string('\truntime.bind_value_ctx(mut ins, ${i}, ${ctx}, ${lower}_slot${i}_get, ${lower}_slot${i}_set)\n')
		}
		.cond {
			b.write_string('\truntime.bind_if_ctx(mut ins, ${i}, ${ctx}, ${lower}_slot${i}_get)\n')
		}
		.list {
			b.write_string('\truntime.bind_list_ctx(mut ins, ${i}, ${ctx}, ${lower}_slot${i}_get)\n')
		}
	}
}

// emit_slot_helper writes the TOP-LEVEL helper fn(s) for slot `i`. They cast the
// `voidptr` ctx back to the component and evaluate the bound expression — the
// closure-free equivalent of the old `fn [mut recv] () {...}` capture, so the
// generated code runs on wasm (where a capturing closure traps; see signal.v).
fn (c &Component) emit_slot_helper(mut b strings.Builder, i int, s slots.SlotDesc) {
	lower := c.name.to_lower()
	recv := c.recv()
	cast := '\tmut ${recv} := unsafe { &${c.name}(ctxp) }\n'
	match s.kind {
		.text {
			b.write_string('fn ${lower}_slot${i}_get(ctxp voidptr) string {\n${cast}')
			b.write_string('\treturn runtime.to_str(${c.qualify(s.expr, true)})\n}\n\n')
		}
		.attr {
			b.write_string('fn ${lower}_slot${i}_get(ctxp voidptr) string {\n${cast}')
			b.write_string('\treturn runtime.to_str(${c.qualify(s.expr, true)})\n}\n\n')
		}
		.event {
			b.write_string('fn ${lower}_slot${i}_evt(ctxp voidptr) {\n${cast}')
			if is_bare_ident(s.handler) && c.has_method(s.handler) {
				b.write_string('\t${recv}.${s.handler}()\n}\n\n')
			} else {
				b.write_string('\t${c.qualify(s.handler, false)}\n}\n\n')
			}
		}
		.bind {
			b.write_string('fn ${lower}_slot${i}_get(ctxp voidptr) string {\n${cast}')
			b.write_string('\treturn runtime.to_str(${c.qualify(s.target_expr, true)})\n}\n\n')
			b.write_string('fn ${lower}_slot${i}_set(ctxp voidptr, v string) {\n${cast}')
			b.write_string('\t${c.qualify(s.target_expr, false)}.set(v)\n}\n\n')
		}
		.cond {
			b.write_string('fn ${lower}_slot${i}_get(ctxp voidptr) bool {\n${cast}')
			b.write_string('\treturn ${c.qualify(s.cond_expr, true)}\n}\n\n')
		}
		.list {
			b.write_string('fn ${lower}_slot${i}_get(ctxp voidptr) int {\n${cast}')
			b.write_string('\treturn ${c.qualify(s.source_expr, true)}.len\n}\n\n')
		}
	}
}

// qualify rewrites a template expression's free identifiers into receiver-scoped
// V: a signal field becomes `recv.name.get()` in a value context (or `recv.name`
// in a call context, so `.set(…)` chains), a plain field/method becomes
// `recv.name`, and anything else (a @for loop variable, an external) is left as
// is. Member tails and string literals are passed through untouched.
fn (c &Component) qualify(expr string, value_ctx bool) string {
	recv := c.recv()
	mut out := ''
	mut i := 0
	for i < expr.len {
		ch := expr[i]
		if ch == `'` || ch == `"` {
			q := ch
			out += expr[i..i + 1]
			i++
			for i < expr.len && expr[i] != q {
				out += expr[i..i + 1]
				i++
			}
			if i < expr.len {
				out += expr[i..i + 1]
				i++
			}
			continue
		}
		if is_ident_start(ch) {
			start := i
			i++
			for i < expr.len && is_ident_part(expr[i]) {
				i++
			}
			name := expr[start..i]
			preceded_by_dot := start > 0 && expr[start - 1] == `.`
			if preceded_by_dot || name in ['true', 'false', 'none'] {
				out += name
			} else if c.is_signal(name) {
				out += '${recv}.${name}' + if value_ctx { '.get()' } else { '' }
			} else if c.has_method(name) && !c.is_field(name) {
				// A computed: a bare method in a value context is CALLED
				// (`{{ doubled }}` → `c.doubled()`), unless the template already
				// wrote the parens; in an event context it stays a method value.
				already_called := i < expr.len && expr[i] == `(`
				if value_ctx && !already_called {
					out += '${recv}.${name}()'
				} else {
					out += '${recv}.${name}'
				}
			} else if c.is_field(name) || c.has_method(name) {
				out += '${recv}.${name}'
			} else {
				out += name // loop variable or external symbol
			}
			continue
		}
		out += expr[i..i + 1]
		i++
	}
	return out
}

fn (c &Component) recv() string {
	if c.name.len == 0 {
		return 'self'
	}
	return c.name[0..1].to_lower()
}

// --- composition / hoisting -------------------------------------------------

@[params]
pub struct HoistInput {
pub:
	name           string
	used_by_routes []string
}

// decide_hoist places a child component: shared across ≥2 routes → core (one
// copy, reused cross-chunk); used by a single route → route-local. This is the
// same usage signal that drives inline-vs-boundary (see COMPONENTS.md §4).
pub fn decide_hoist(input HoistInput) HoistDecision {
	if input.used_by_routes.len >= 2 {
		return .core
	}
	return .route_local
}

// --- logic-file parsing -----------------------------------------------------

// parse_logic extracts the @[component] struct's name, fields, and method names
// from the `.v` logic file. It is a focused scan, not a full V parser: enough to
// resolve template references and emit codegen receivers.
fn parse_logic(src string) !(string, []Field, []string) {
	// Anchor on the @[component] attribute (which immediately precedes the
	// struct) so a stray "struct" in a doc comment isn't picked up as the name.
	anchor := index_of(src, '@[component]', 0)
	start := if anchor >= 0 { anchor } else { 0 }
	si := find_word_from(src, 'struct', start)
	if si < 0 {
		return error('no @[component] struct found in logic file')
	}
	mut j := si + 'struct'.len
	for j < src.len && is_space(src[j]) {
		j++
	}
	ns := j
	for j < src.len && is_ident_part(src[j]) {
		j++
	}
	name := src[ns..j]
	if name == '' {
		return error('struct keyword not followed by a name')
	}
	for j < src.len && src[j] != `{` {
		j++
	}
	if j >= src.len {
		return error('struct ${name} has no body')
	}
	body_start := j + 1
	mut depth := 1
	mut k := body_start
	for k < src.len && depth > 0 {
		if src[k] == `{` {
			depth++
		} else if src[k] == `}` {
			depth--
			if depth == 0 {
				break
			}
		}
		k++
	}
	body := src[body_start..k]
	return name, parse_fields(body), parse_methods(src, name)
}

fn parse_fields(body string) []Field {
	mut out := []Field{}
	for raw in body.split('\n') {
		line := raw.trim_space()
		if line == '' || line.starts_with('//') {
			continue
		}
		// access-modifier line: `mut:`, `pub:`, `pub mut:`, …
		if line.ends_with(':') {
			head := line.trim_right(':').trim_space()
			if head in ['', 'pub', 'mut', 'pub mut', 'global', '__global', 'module'] {
				continue
			}
		}
		// embedded struct (`vcsr.Component`): a single token, no field name
		if !line.contains(' ') && !line.contains('\t') {
			continue
		}
		// `name type [= default]`
		mut p := 0
		for p < line.len && !is_space(line[p]) {
			p++
		}
		fname := line[0..p]
		if fname == '' || !is_ident_start(fname[0]) {
			continue
		}
		for p < line.len && is_space(line[p]) {
			p++
		}
		mut q := p
		for q < line.len && line[q] != `=` {
			q++
		}
		typ_str := line[p..q].trim_space()
		mut typ := typ_str
		mut is_sig := false
		gi := index_of(typ_str, 'Signal[', 0)
		if gi >= 0 {
			inner := gi + 'Signal['.len
			mut d := 1
			mut r := inner
			for r < typ_str.len && d > 0 {
				if typ_str[r] == `[` {
					d++
				} else if typ_str[r] == `]` {
					d--
					if d == 0 {
						break
					}
				}
				r++
			}
			typ = typ_str[inner..r]
			is_sig = true
		}
		out << Field{
			name:      fname
			typ:       typ
			is_signal: is_sig
		}
	}
	return out
}

fn parse_methods(src string, struct_name string) []string {
	mut out := []string{}
	mut i := 0
	for {
		fi := find_word_from(src, 'fn', i)
		if fi < 0 {
			break
		}
		mut j := fi + 'fn'.len
		for j < src.len && is_space(src[j]) {
			j++
		}
		if j >= src.len || src[j] != `(` {
			i = fi + 'fn'.len // `fn name(` (free function) or unexpected → not a method
			continue
		}
		rec_start := j + 1
		mut depth := 1
		mut k := rec_start
		for k < src.len && depth > 0 {
			if src[k] == `(` {
				depth++
			} else if src[k] == `)` {
				depth--
				if depth == 0 {
					break
				}
			}
			k++
		}
		recv := src[rec_start..k].trim_space() // e.g. `mut c Counter`
		toks := recv.split(' ').filter(it.trim_space() != '')
		mut m := k + 1
		for m < src.len && is_space(src[m]) {
			m++
		}
		mstart := m
		for m < src.len && is_ident_part(src[m]) {
			m++
		}
		mname := src[mstart..m]
		if toks.len > 0 {
			rtyp := toks[toks.len - 1].trim_left('&')
			if rtyp == struct_name && mname != '' {
				out << mname
			}
		}
		i = if m > fi { m } else { fi + 'fn'.len }
	}
	return out
}

// --- CSS scoping (a minimal pass; phase 05 does the full scope+atomize) ------

// scope_css appends a component-unique suffix to each top-level class selector
// so two components' `.box` can't collide. This is the phase-04 placeholder;
// phase 05's `css` module supersedes it with atomization and tree-shaking.
fn scope_css(name string, css string) string {
	if css.trim_space() == '' {
		return ''
	}
	suffix := '_' + scope_token(name)
	mut out := ''
	mut depth := 0
	mut i := 0
	for i < css.len {
		ch := css[i]
		if ch == `{` {
			depth++
			out += '{'
			i++
			continue
		}
		if ch == `}` {
			if depth > 0 {
				depth--
			}
			out += '}'
			i++
			continue
		}
		if depth == 0 && ch == `.` && i + 1 < css.len && is_ident_start(css[i + 1]) {
			out += '.'
			i++
			start := i
			for i < css.len && (is_ident_part(css[i]) || css[i] == `-`) {
				i++
			}
			out += css[start..i] + suffix
			continue
		}
		out += css[i..i + 1]
		i++
	}
	return out
}

// scope_token derives a short, deterministic, name-unique suffix (FNV-1a hex).
fn scope_token(name string) string {
	mut h := u32(2166136261)
	for ch in name {
		h = (h ^ u32(ch)) * u32(16777619)
	}
	return h.hex()
}

// --- small helpers ----------------------------------------------------------

fn collect_children(node ast.Node, mut out []string) {
	if node.kind == .component && node.tag !in out {
		out << node.tag
	}
	for child in node.children {
		collect_children(child, mut out)
	}
}

fn slot_kind_name(k slots.SlotKind) string {
	return match k {
		.text { 'text' }
		.attr { 'attr' }
		.event { 'event' }
		.bind { 'bind' }
		.cond { 'cond' }
		.list { 'list' }
	}
}

fn render_path(p []int) string {
	if p.len == 0 {
		return '[]int{}'
	}
	mut parts := []string{cap: p.len}
	for n in p {
		parts << n.str()
	}
	return '[' + parts.join(', ') + ']'
}

// esc makes `s` safe to embed inside a single-quoted V string literal.
fn esc(s string) string {
	return s.replace('\\', '\\\\').replace("'", "\\'")
}

fn is_bare_ident(s string) bool {
	if s == '' || !is_ident_start(s[0]) {
		return false
	}
	for ch in s {
		if !is_ident_part(ch) {
			return false
		}
	}
	return true
}

fn is_space(c u8) bool {
	return c == ` ` || c == `\t` || c == `\n` || c == `\r`
}

fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn is_ident_part(c u8) bool {
	return is_ident_start(c) || (c >= `0` && c <= `9`)
}

fn index_of(s string, sub string, from int) int {
	if sub == '' {
		return from
	}
	mut i := if from < 0 { 0 } else { from }
	for i + sub.len <= s.len {
		if s[i..i + sub.len] == sub {
			return i
		}
		i++
	}
	return -1
}

// find_word_from finds `word` as a whole token (identifier-bounded) at or after
// `from`, or -1.
fn find_word_from(src string, word string, from int) int {
	mut i := if from < 0 { 0 } else { from }
	for {
		idx := index_of(src, word, i)
		if idx < 0 {
			return -1
		}
		before_ok := idx == 0 || !is_ident_part(src[idx - 1])
		after := idx + word.len
		after_ok := after >= src.len || !is_ident_part(src[after])
		if before_ok && after_ok {
			return idx
		}
		i = idx + 1
	}
	return -1
}
