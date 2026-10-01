// Browser check for the counter, run by tools/browser-smoke/example.mjs:
// the wasm-rendered UI shows 0/0, and each click on the real +1 button re-patches
// only the bound <h1> (count) and <span> (doubled).
export default async (page, { ok }) => {
  const read = () => page.evaluate(() => [
    document.querySelector('#app h1')?.textContent,
    document.querySelector('#app .muted span')?.textContent,
  ]);
  const at = (count) => page.waitForFunction((c) => document.querySelector('#app h1')?.textContent === c, String(count));

  ok(JSON.stringify(await read()) === '["0","0"]', 'renders count 0, doubled 0');
  await page.click('#app button');
  await at(1);
  ok(JSON.stringify(await read()) === '["1","2"]', 'click → count 1, doubled 2');
  await page.click('#app button');
  await page.click('#app button');
  await at(3);
  ok(JSON.stringify(await read()) === '["3","6"]', 'three clicks → count 3, doubled 6');
};
