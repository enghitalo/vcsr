// Reports route: LAZY — compiled into route-reports.wasm, fetched on first
// navigation. Async data fetch, route param, loading/error states, and reuse of
// the shared Button (which lives in core, not duplicated here). Illustrative.
module components

import vcsr { Signal, signal }
import vcsr.router
import dom { fetch } // generated Web API binding
import shared { Button }
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

pub fn (mut r Reports) view() vcsr.View {
	return $vui('
		<main class="reports">
			<p class="muted" @if=${r.loading.get()}>loading…</p>
			<p class="error" @if=${r.error.get() != ""}>${r.error}</p>

			<article @if=${r.report.get() != none}>
				<h1>${r.report.get()?.title}</h1>
				<p class="total">total: ${r.report.get()?.total}</p>
				${Button{ label: "Export CSV", on_click: r.export_csv }}
			</article>

			<a @link="/">← home</a>
		</main>
	')
}

fn (r Reports) export_csv() {}

pub fn (r Reports) style() string {
	return $css('
		.reports { display: grid; gap: 1rem; padding: 2rem; max-width: 28rem; }
		.muted   { color: var(--fg-muted); }
		.error   { color: var(--danger); }
		.total   { font-size: 1.5rem; font-weight: 600; }
	')
}
