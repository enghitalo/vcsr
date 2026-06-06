// Example SPA: router + code splitting + shared store. Illustrative source.
module main

import vcsr
import vcsr.router { Route }
import components { Home, NotFound, Reports, TodoList }
import store { AppStore }

fn main() {
	mut app := vcsr.new_app(
		root:  '#app'
		store: AppStore.new() // global reactive store, injected into components
	)

	app.routes([
		Route{
			path:      '/'
			component: Home
		},
		Route{
			path:      '/todos'
			component: TodoList
		},
		Route{
			path:      '/reports/:id'
			component: Reports
			lazy:      true // compiled into its own route-reports.wasm chunk
		},
		Route{
			path:      '/*'
			component: NotFound
		},
	])

	app.mount()
}
