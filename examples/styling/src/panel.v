// Panel — LOGIC only; the template is panel.html and its styles panel.css.
module main

import vcsr { Signal, signal }

@[component]
struct Panel {
mut:
	dark &Signal[bool]   = signal(false)
	size &Signal[string] = signal('big')
}

fn (mut p Panel) toggle() {
	p.dark.set(!p.dark.get())
}

fn (mut p Panel) resize() {
	p.size.set(if p.size.get() == 'big' { 'small' } else { 'big' })
}
