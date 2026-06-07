// Micro-benchmark for the vcsr front end (phases 01-03: parse -> slots -> bind).
//
// Purpose: decide, with data, whether a zero-copy `Slice {start, len}`
// representation (vanilla-style) is worth adopting over the current
// string-allocating parser. It measures per-stage time at a realistic component
// size and at a pathological large one, plus the full-pipeline throughput and
// "allocation amplification" (bytes allocated / bytes of input).
//
// Findings (see bench/README.md) — keep this as a regression guard.
//
// Run:  ln -s "$PWD" ~/.vmodules/vcsr        # once, so `import vcsr.*` resolves
//       v -prod run bench/parse_bench.v
module main

import time
import strings
import vcsr.parser
import vcsr.slots
import vcsr.bind

// Boehm GC (V's default): cumulative bytes allocated since program start.
fn C.GC_get_total_bytes() usize

// A realistic component: a handful of elements, events, a bind, an attr, a list
// and a conditional. ~200 bytes, like a real `.html` file.
const realistic =
	'<form class="f" @submit.prevent="save"><input @bind="draft" /><a :href="url">go</a>' +
	'<ul><li @for="x in xs" :key="x.id"><span>{{ x.name }}</span></li></ul>' +
	'<p @if="ok"><b>{{ msg }}</b></p></form>'

// A pathologically large single template (500 inlined rows). Real apps don't
// write these — lists use one `@for` row — but it exposes any super-linear cost.
fn gen_large(rows int) string {
	mut sb := strings.new_builder(rows * 110 + 64)
	sb.write_string('<section class="list">')
	for i in 0 .. rows {
		sb.write_string('<div class="row" data-i="')
		sb.write_decimal(i)
		sb.write_string('"><span class="name">{{ item')
		sb.write_decimal(i)
		sb.write_string(' }}</span><button @click="act')
		sb.write_decimal(i)
		sb.write_string('">x</button></div>')
	}
	sb.write_string('</section>')
	return sb.str()
}

fn stages(label string, t string, passes int) {
	mut p_ns, mut s_ns, mut b_ns, mut acc := i64(0), i64(0), i64(0), 0
	for _ in 0 .. passes {
		mut sw := time.new_stopwatch()
		tree := parser.parse_template(t) or { panic(err) }
		p_ns += sw.elapsed().nanoseconds()
		sw = time.new_stopwatch()
		ct := slots.compile(tree) or { panic(err) }
		s_ns += sw.elapsed().nanoseconds()
		sw = time.new_stopwatch()
		bp := bind.plan(ct) or { panic(err) }
		b_ns += sw.elapsed().nanoseconds()
		acc += ct.slots.len + bp.bindings.len
	}
	pp := f64(passes)
	println('${label} (${t.len} B, ${passes} passes):')
	println('  parse ${f64(p_ns) / pp / 1000.0:7.2} us   slots ${f64(s_ns) / pp / 1000.0:7.2} us   bind ${f64(b_ns) / pp / 1000.0:7.2} us   total ${f64(
		p_ns + s_ns + b_ns) / pp / 1000.0:7.2} us   (sink ${acc})')
}

fn main() {
	large := gen_large(500)

	// per-stage timing
	stages('realistic component', realistic, 200_000)
	stages('large (500 rows)    ', large, 300)

	// full-pipeline allocation amplification on the large template
	passes := 1000
	parser.parse_template(large) or { panic(err) } // warm up
	b0 := u64(C.GC_get_total_bytes())
	mut acc := 0
	for _ in 0 .. passes {
		tree := parser.parse_template(large) or { panic(err) }
		ct := slots.compile(tree) or { panic(err) }
		bp := bind.plan(ct) or { panic(err) }
		acc += ct.slots.len + bp.bindings.len
	}
	alloc := u64(C.GC_get_total_bytes()) - b0
	amp := f64(alloc) / (f64(large.len) * f64(passes))
	println('large: alloc ${f64(alloc) / f64(passes) / 1024.0:.0} KB/pass, amplification ${amp:.0}x (allocated/input)  (sink ${acc})')
}
