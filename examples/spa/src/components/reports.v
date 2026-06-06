// Reports route — LOGIC only (template: reports.html, styles: reports.css).
// LAZY: compiled into route-reports.wasm, fetched on first navigation. Async
// fetch, route param, loading/error states. Illustrative source.
module components

import vcsr { Signal, signal }
import vcsr.router
import dom { fetch } // generated Web API binding
import json

pub struct Report {
pub:
	id    int
	title string
	total f64
}

@[component]
pub struct Reports {
	vcsr.Component
mut:
	report  Signal[?Report] = signal(?Report(none))
	loading Signal[bool]    = signal(true)
	error   Signal[string]  = signal('')
}

pub fn (mut r Reports) on_mount() {
	// coroutine on the browser event loop; `!` suspends without blocking the UI
	spawn r.load()
}

fn (mut r Reports) load() {
	id := router.param('id')
	resp := fetch('/api/reports/${id}') or {
		r.error.set(err.msg())
		r.loading.set(false)
		return
	}
	report := json.decode(Report, resp.text()) or {
		r.error.set('invalid response')
		r.loading.set(false)
		return
	}
	r.report.set(report)
	r.loading.set(false)
}

pub fn (r Reports) export_csv() {}
