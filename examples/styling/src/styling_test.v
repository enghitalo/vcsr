// The GENERATED panel.gen.v and badge.gen.v on the native mock: markup and CSS
// carry the same scope attribute, each component's sheet is added once, and the
// class bindings keep the static class.
module main

import vcsr.css
import vcsr.runtime

fn test_markup_and_css_share_the_scope_attribute() {
	mut p := Panel{}
	mut b := Badge{}
	pv := p.view()
	bv := b.view()
	pa := css.scope_attr('Panel')
	ba := css.scope_attr('Badge')
	assert pa != ba
	assert pv.html().contains('<p class="label" ${pa}="">')
	assert bv.html().contains('<p class="label" ${ba}="">')
	sheets := runtime.styles()
	assert sheets.any(it.contains('.label[${pa}]{margin: 0; color: rgb(200, 30, 30);}'))
	assert sheets.any(it.contains('.label[${ba}]{margin: 0; color: rgb(30, 60, 200); font-weight: 700;}'))
	assert sheets.any(it.contains('@keyframes spin{') && it.contains('@media (min-width: 600px){.panel[${pa}]'))
	// another Panel adds no second copy
	mut p2 := Panel{}
	_ := p2.view()
	assert runtime.styles().len == sheets.len
}

fn test_class_toggle_and_dynamic_classes_keep_the_static_class() {
	mut p := Panel{}
	v := p.view()
	assert v.html().starts_with('<section class="panel big"')
	p.toggle()
	assert v.html().starts_with('<section class="panel big dark"')
	p.resize()
	assert v.html().starts_with('<section class="panel dark small"')
	p.toggle()
	assert v.html().starts_with('<section class="panel small"')
}
