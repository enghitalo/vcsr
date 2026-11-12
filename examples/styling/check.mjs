// Browser check for the styling example, run by tools/browser-smoke/example.mjs.
// It asserts COMPUTED styles, so a scoped rule that doesn't match its markup, or
// one component's rule reaching another's elements, fails here.
export default async (page, { ok }) => {
  const style = (sel, prop) => page.$eval(`#app ${sel}`, (e, p) => getComputedStyle(e)[p], prop);

  ok(await page.evaluate(() => [...document.head.querySelectorAll('style')].filter((s) => s.textContent.includes('[data-s-')).length) === 2,
    'each component added its scoped stylesheet to <head>, once');
  ok(await style('.panel .label', 'color') === 'rgb(200, 30, 30)', "Panel's .label is red");
  ok(await style('.badge .label', 'color') === 'rgb(30, 60, 200)', "Badge's .label is blue: same class name, no leak");
  ok(await style('.badge .label', 'fontWeight') === '700' && await style('.panel .label', 'fontWeight') === '400',
    "Badge's bold .label doesn't reach Panel's");
  ok(await style('.panel', 'paddingTop') === '24px', '@media (min-width: 600px) applies at 900px');
  ok(await style('.spinner', 'animationName') === 'spin', '@keyframes spin is the spinner animation');
  ok(await page.$eval('#app .panel', (e) => e.className) === 'panel big' && await style('.panel', 'fontSize') === '20px',
    ':class adds `big` beside the static `panel`');
  ok(await style('.title', 'color') === 'rgb(29, 35, 48)', 'the title is dark on a light panel');

  await page.click('#app .toggle');
  ok(await style('.panel', 'backgroundColor') === 'rgb(29, 35, 48)', 'class:dark toggles the panel dark');
  ok(await style('.title', 'color') === 'rgb(255, 255, 255)', 'an ancestor themes a descendant: .dark .title is white');

  await page.click('#app .resize');
  ok(await page.$eval('#app .panel', (e) => e.className) === 'panel dark small' && await style('.panel', 'fontSize') === '14px',
    ':class swaps big for small; the static class and class:dark stay');

  await page.setViewportSize({ width: 500, height: 640 });
  ok(await style('.panel', 'paddingTop') === '16px', 'below 600px the @media rule no longer applies');
  await page.setViewportSize({ width: 900, height: 640 });
};
