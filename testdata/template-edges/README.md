# testdata/template-edges

One component holding the template-language edge cases found by the review of
PR #15 (issues #16–#33): `@if`/`@for` anchors, two `@bind` inputs, `${}` in a
handler, format specifiers, a keyword-named field, HTML5 character references,
the `{{{{` escape, `<?` in text, `<pre>`/`<textarea>` newlines, and a component
named like an HTML tag.

[`expected.html`](expected.html) is the render both backends must produce:

- natively, `src/edges_test.v` runs the generated `edges.gen.v` on the mock DOM
  (`make test`);
- in Chrome, [`check.mjs`](check.mjs) loads the wasm build and compares
  `#app`'s `innerHTML`, then drives the inputs and buttons (`make examples`).

It is a test fixture, not an example: `make screenshots` skips it.
