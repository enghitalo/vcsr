// Native entry (mock DOM), so the example also builds and tests without a browser.
module main

import vcsr.runtime

fn main() {
	mut p := Panel{}
	mut b := Badge{}
	println(p.view().html())
	println(b.view().html())
	println(runtime.styles().join('\n'))
}
