// Todos route: two-way binding, keyed list rendering, conditional render,
// local state. Ships in core.wasm (eager route). Illustrative source.
module components

import vcsr { Signal, computed, signal }

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

pub fn (mut t TodoList) view() vcsr.View {
	remaining := computed(fn [t] () int {
		return t.items.get().filter(!it.done).len
	})

	return $vui('
		<main class="todos">
			<header>
				<h1>Todos</h1>
				<span class="badge">${remaining} left</span>
			</header>

			<form @submit.prevent=${t.add}>
				<input placeholder="What needs doing?" @bind=${t.draft} @keydown.enter=${t.add} />
				<button type="submit">add</button>
			</form>

			<ul>
				<li @for=${item in t.items} :key=${item.id} class:done=${item.done}>
					<input type="checkbox" @bind=${item.done} />
					<span class="text">${item.text}</span>
					<button class="x" @click=${fn [t, item] () { t.remove(item.id) }}>×</button>
				</li>
			</ul>

			<p class="empty" @if=${t.items.get().len == 0}>Nothing here yet 🎉</p>
			<a @link="/">← home</a>
		</main>
	')
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

pub fn (t TodoList) style() string {
	return $css('
		.todos  { display: grid; gap: 1rem; padding: 2rem; max-width: 32rem; }
		header  { display: flex; align-items: baseline; gap: .75rem; }
		.badge  { font-size: .8rem; color: var(--fg-muted); }
		form    { display: flex; gap: .5rem; }
		input:not([type="checkbox"]) { flex: 1; padding: .5rem .75rem;
		          border: 1px solid var(--border); border-radius: .5rem; }
		ul      { list-style: none; padding: 0; display: grid; gap: .25rem; }
		li      { display: flex; align-items: center; gap: .5rem; }
		.done .text { text-decoration: line-through; color: var(--fg-muted); }
		.x      { margin-left: auto; border: none; background: none; cursor: pointer; }
		.empty  { color: var(--fg-muted); }
	')
}
