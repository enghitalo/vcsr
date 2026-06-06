// 404 fallback route. Illustrative source.
module components

import vcsr

@[component]
pub struct NotFound {
	vcsr.Component
}

pub fn (n NotFound) view() vcsr.View {
	return $vui('
		<main class="notfound">
			<h1>404</h1>
			<p class="muted">No such route.</p>
			<a @link="/">back home</a>
		</main>
	')
}

pub fn (n NotFound) style() string {
	return $css('
		.notfound { display: grid; gap: .5rem; padding: 3rem 2rem; text-align: center; }
		.muted    { color: var(--fg-muted); }
	')
}
