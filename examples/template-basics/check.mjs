// Browser check for template-basics, run by tools/browser-smoke/example.mjs.
export default async (page, { ok }) => {
  const text = (sel) => page.textContent(`#app ${sel}`);
  const squash = (s) => s.replace(/\s+/g, ' ').trim();

  ok(await text('h1') === 'Hello, World!', 'mixed text + interpolation: "Hello, World!"');
  ok(squash(await text('.stats')) === "5 characters, a short name — true that it's under six.",
    'interpolations beside elements render in place; entity decoded; `<` inside {{ }}');
  ok(await text('.shouts') === 'Shouted 0 times.', "string interpolation + if-expression: 'Shouted 0 times.'");
  ok(squash(await text('footer')) === '© 2026 · costs $0 · 1 < 2', 'static entities and a literal $ survive');

  await page.fill('#app input', 'Ada');
  await page.waitForFunction(() => document.querySelector('#app h1').textContent === 'Hello, Ada!');
  ok(squash(await text('.stats')).startsWith('3 characters, a short name'), 'typing re-patches h1 and the anchored counts');

  await page.click('#app .actions button');
  await page.waitForFunction(() => document.querySelector('#app h1').textContent === 'Hello, ADA!');
  ok(await text('.shouts') === 'Shouted 1 time.', 'Shout: name upper-cased, singular "time"');

  await page.fill('#app input', 'Margaret Hamilton');
  await page.waitForFunction(() => document.querySelector('#app .stats b').textContent === 'long');
  ok(squash(await text('.stats')) === "17 characters, a long name — false that it's under six.", 'computed re-evaluates: long / false');
};
