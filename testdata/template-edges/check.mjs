// Browser check for testdata/template-edges, run by tools/browser-smoke/example.mjs
// (`make examples`). The page must render exactly what the native mock renders
// (expected.html, asserted by src/edges_test.v), then react like it.
import { readFileSync } from 'node:fs';

const expected = readFileSync(new URL('./expected.html', import.meta.url), 'utf8').trim();

export default async (page, { ok }) => {
  const app = () => page.evaluate(() => document.querySelector('#app').innerHTML);
  const text = (sel) => page.textContent(`#app ${sel}`);

  const html = await app();
  ok(html === expected, 'renders exactly expected.html, as the native mock does'
    + (html === expected ? '' : `\n       got:      ${html}\n       expected: ${expected}`));

  await page.click('#app .toggle');
  await page.click('#app .add');
  const after = await app();
  ok(after.includes('<!--@if false-->') && after.includes('<ul class="for"><!--@for 3--></ul>'),
    '#16 #28: @if/@for mounted, and their anchors follow the signals');

  await page.fill('#app .first', 'Margaret');
  await page.fill('#app .last', 'Ham');
  ok(await text('.who') === 'Hello, Margaret Ham!', '#17: two @bind inputs keep their own strings');

  await page.click('#app .greet');
  ok(await text('.msg') === 'Hi Margaret!', '#24: ${first} in a handler reads the signal');

  ok(await page.$eval('#app .ta', (e) => e.value) === 'x := 1', '#27: the textarea value has no leading newline');
  ok(await text('.ent') === await text('.ent-static'), '#21: references in a text slot read like static text');

  // second review of #15
  ok(await page.$eval('#app .caps', (e) => getComputedStyle(e).color) === 'rgb(0, 128, 128)',
    'an interpolated <style> body applies; HTML in capitals is HTML');
  ok(await page.$eval('#app .ta2', (e) => e.value) === 'Dear Margaret,<br>thanks', 'a <textarea> body is text, interpolated');
  await page.fill('#app .typed', 'abc');
  ok(await text('.log') === 'typed abc', '@bind writes the value before @input runs');
  await page.click('#app .go');
  ok(await text('.msg') === '/about/Margaret', "a keyword-named method; ${first.get()} isn't read twice");
  ok(await page.$eval('#app .bom', (e) => e.textContent.codePointAt(0)) === 0xFEFF, 'a text slot keeps a leading U+FEFF');
};
