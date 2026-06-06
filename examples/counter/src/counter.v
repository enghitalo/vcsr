// Counter — LOGIC only. The template is counter.html and the styles are
// counter.css; vcsr pairs them by basename and generates counter.gen.v with the
// view()/style() implementations. There is no $vui/$css here (no V changes).
module main

import vcsr { Signal, signal }

@[component]
struct Counter {
	vcsr.Component
mut:
	count Signal[int] = signal(0)
}

fn (mut c Counter) inc() {
	c.count.update(fn (n int) int {
		return n + 1
	})
}

// `doubled` is exposed to the template as a computed value. vcsr resolves
// `{{ doubled }}` to this method and memoizes it.
fn (c Counter) doubled() int {
	return c.count.get() * 2
}
