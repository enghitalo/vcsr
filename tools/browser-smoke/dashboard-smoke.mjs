// dashboard-smoke.mjs — drive the "vcsr console" complex app in a real browser.
//
// Same safety design as browser-smoke.mjs: ONE Node process holds both the
// single-process static server (idles at ~0% CPU) and the Playwright driver,
// with a hard self-timeout. Never use vanilla's per-core epoll server here.
//
// Usage:
//   cd tools/browser-smoke && npm install
//   node dashboard-smoke.mjs               # serves ../../testdata/dashboard-app/dist
// Builds the bundle first if dist/ is missing (anything calling
// bundle.build('testdata/dashboard-app', release: true)).

import http from 'node:http';
import { readFileSync, existsSync, statSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DIST = process.env.VCSR_DIST || path.resolve(HERE, '../../testdata/dashboard-app/dist');
const SHOTS = path.join(HERE, 'screenshots', 'dashboard');

if (!existsSync(path.join(DIST, 'index.html'))) {
  console.error(`No bundle at ${DIST} — build testdata/dashboard-app first.`);
  process.exit(1);
}
mkdirSync(SHOTS, { recursive: true });
setTimeout(() => { console.error('!! safety timeout (60s)'); process.exit(2); }, 60_000).unref();

const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json', '.map': 'application/json' };
const server = http.createServer((req, res) => {
  try {
    const p = decodeURIComponent(req.url.split('?')[0]);
    if (p.includes('..')) { res.writeHead(404); return res.end(); }
    let file = p.replace(/^\/+/, '') || 'index.html';
    if (file === 'favicon.ico') { res.writeHead(204); return res.end(); }
    let full = path.join(DIST, file);
    if (!existsSync(full) || !statSync(full).isFile()) {
      if (file.split('/').pop().includes('.')) { res.writeHead(404); return res.end('404'); }
      file = 'index.html'; full = path.join(DIST, file);  // SPA fallback
    }
    const ae = req.headers['accept-encoding'] || '';
    let body, enc = null;
    if (/\bbr\b/.test(ae) && existsSync(full + '.br')) { body = readFileSync(full + '.br'); enc = 'br'; }
    else body = readFileSync(full);
    const h = { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'content-length': body.length };
    if (enc) h['content-encoding'] = enc;
    res.writeHead(200, h); res.end(body);
  } catch (e) { res.writeHead(500); res.end(String(e)); }
});
const port = await new Promise(r => server.listen(0, '127.0.0.1', () => r(server.address().port)));
const BASE = `http://127.0.0.1:${port}`;
console.log('dashboard on', BASE);

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✅', m); } else { fail++; console.log('  ❌', m); } };
const exe = ['/usr/bin/google-chrome-stable', '/usr/bin/google-chrome', '/usr/bin/chromium'].find(existsSync);
const browser = await chromium.launch(exe
  ? { executablePath: exe, headless: true, args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'] }
  : { headless: true });
const shot = (pg, n) => pg.screenshot({ path: `${SHOTS}/${n}.png`, fullPage: true });

try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
  const cerr = [];
  page.on('console', m => m.type() === 'error' && cerr.push(m.text()));
  await page.goto(BASE + '/', { waitUntil: 'networkidle' });
  await page.waitForSelector('html[data-vcsr="mounted"]', { timeout: 8000 });

  console.log('\n[1] initial render (light)');
  ok(await page.getByRole('heading', { name: 'vcsr console' }).count() > 0, 'header "vcsr console" present');
  ok(await page.locator('.card').count() === 3, `3 cards rendered (${await page.locator('.card').count()})`);
  ok(await page.locator('.app.light').count() >= 1, 'light theme applied');
  await shot(page, '01-initial-light');

  console.log('\n[2] counter — events + computed');
  await page.getByRole('button', { name: '+', exact: true }).click();
  await page.getByRole('button', { name: '+', exact: true }).click();
  await page.getByRole('button', { name: '+', exact: true }).click();
  await page.getByRole('button', { name: '−', exact: true }).click();
  ok((await page.locator('.num').textContent()) === '2', `counter == 2 (${await page.locator('.num').textContent()})`);
  ok(await page.getByText('× 2 = 4').count() > 0, 'computed "× 2 = 4" updated');

  console.log('\n[3] todos — input, add, toggle, computed footer');
  await page.locator('input').fill('Ship vcsr 1.0');
  await page.getByRole('button', { name: 'Add' }).click();
  await page.locator('input').fill('Write the changelog');
  await page.getByRole('button', { name: 'Add' }).click();
  ok(await page.locator('.item').count() === 2, `2 todos added (${await page.locator('.item').count()})`);
  await page.locator('.item .txt').first().click();
  ok(await page.locator('.txt.done').count() === 1, 'first todo toggled done');
  ok(await page.getByText('1 done / 2 total').count() > 0, 'computed footer "1 done / 2 total"');
  await shot(page, '02-counter-todos');

  console.log('\n[4] async fetch');
  await page.getByRole('button', { name: 'GET /manifest.json' }).click();
  await page.waitForFunction(() => /fetched \d+ bytes @/.test(document.body.textContent), { timeout: 5000 });
  ok(true, 'async fetch resolved → status updated from the callback');
  await shot(page, '03-after-fetch');

  console.log('\n[5] theme toggle + localStorage persistence');
  await page.locator('.ghost').click();
  ok(await page.locator('.app.dark').count() >= 1, 'dark theme applied on toggle');
  await shot(page, '04-dark');
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('html[data-vcsr="mounted"]');
  ok(await page.locator('.app.dark').count() >= 1, 'theme persisted across reload (localStorage)');

  console.log('\n[6] about tab (conditional view)');
  await page.getByRole('button', { name: 'About' }).click();
  ok(await page.getByRole('heading', { name: 'About' }).count() > 0, 'About view rendered on tab switch');
  await shot(page, '05-about-dark');

  console.log('\n[7] mobile viewport');
  const mob = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await mob.goto(BASE + '/', { waitUntil: 'networkidle' });
  await mob.waitForSelector('html[data-vcsr="mounted"]');
  ok(await mob.locator('.card').count() === 3, 'renders 3 cards on mobile');
  await shot(mob, '06-mobile-dark');
  await mob.close();

  ok(cerr.length === 0, `no console errors (${cerr.length})`);
} catch (e) { console.error('FATAL', e); fail++; }
finally { await browser.close(); server.close(); }

console.log(`\n==== ${pass} passed, ${fail} failed ====`);
process.exit(fail === 0 ? 0 : 1);
