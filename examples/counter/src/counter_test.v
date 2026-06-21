// Integration: the GENERATED counter.gen.v, wired to the real runtime, actually
// reacts. This compiles the whole triplet (counter.v logic + counter.gen.v
// view()/style() + the runtime) and drives it — the end-to-end proof that the
// codegen contract and the runtime agree.
//
//   v -enable-globals test examples/counter/src/
module main

fn test_generated_counter_reacts() {
	mut c := Counter{}
	dom := c.view() // the generated view(): clone skeleton + wire reactive slots
	assert dom.html().contains('<h1>0</h1>')
	assert dom.html().contains('double <span>0</span>') // doubled = 0

	c.inc() // exactly what the @click="inc" handler runs
	assert dom.html().contains('<h1>1</h1>')
	assert dom.html().contains('<span>2</span>') // doubled recomputed reactively

	c.inc()
	assert dom.html().contains('<h1>2</h1>')
	assert dom.html().contains('<span>4</span>')
}
