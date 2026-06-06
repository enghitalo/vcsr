// Todos route — LOGIC only (template: todos.html, styles: todos.css).
// Ships in core.wasm (eager route). Illustrative source.
module components

import vcsr { Signal, signal }

pub struct Todo {
pub mut:
	id   int
	text string
	done bool
}

@[component]
pub struct TodoList {
	vcsr.Component
mut:
	items   Signal[[]Todo] = signal([]Todo{})
	draft   Signal[string] = signal('')
	next_id int = 1
}

// Exposed to the template as `{{ remaining }}` (memoized computed).
pub fn (t TodoList) remaining() int {
	return t.items.get().filter(!it.done).len
}

pub fn (mut t TodoList) add() {
	text := t.draft.get().trim_space()
	if text == '' {
		return
	}
	id := t.next_id
	t.next_id++
	mut list := t.items.get().clone()
	list << Todo{
		id:   id
		text: text
	}
	t.items.set(list)
	t.draft.set('')
}

pub fn (mut t TodoList) remove(id int) {
	t.items.update(fn [id] (list []Todo) []Todo {
		return list.filter(it.id != id)
	})
}
