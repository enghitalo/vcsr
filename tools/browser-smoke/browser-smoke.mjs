// browser-smoke.mjs — run a vcsr-built dist/ in a real browser and assert it works.
//
// SAFETY DESIGN (read this before changing it):
//   This harness is ONE Node process that holds BOTH a tiny static file server
//   (event-driven http.createServer — idles at ~0% CPU) AND the Playwright
//   driver, plus a hard self-timeout. So at any instant there is exactly one
//   server and one browser, and BOTH die when this process exits.
//
//   Do NOT serve the bundle here with vanilla's http_server for this smoke test:
//   that server spawns a busy-polling worker per CPU core, and launching it
//   repeatedly (or failing to reap it) saturates every core. (Phase 10 already
//   proves the vanilla serving contract at the HTTP-bytes level, socket-free.)
//
// Usage:
//   cd tools/browser-smoke && npm install        # installs playwright (uses system Chrome)
//   node browser-smoke.mjs                        # serves ../../testdata/fixture-app/dist
//   VCSR_DIST=/abs/path/to/dist node browser-smoke.mjs   # serve a different bundle
//   CHROME_BIN=/usr/bin/chromium node browser-smoke.mjs  # pick the browser binary
// Exit code 0 = all checks passed.

import http from 'node:http';
import { readFileSync, existsSync, statSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DIST = process.env.VCSR_DIST || path.resolve(HERE, '../../testdata/fixture-app/dist');
const SHOTS = path.join(HERE, 'screenshots');

if (!existsSync(path.join(DIST, 'index.html'))) {
  console.error(`No bundle at ${DIST}\n  Build it first:  v run <driver that calls bundle.build('testdata/fixture-app', release: true)>`);
  process.exit(1);
}
mkdirSync(SHOTS, { recursive: true });

// Hard kill-switch: this process cannot outlive 60s, no matter what hangs.
setTimeout(() => { console.error('!! safety timeout (60s) — exiting'); process.exit(2); }, 60_000).unref();

// ---- single-process static server (mirrors vanilla static_assets behaviour) ----
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm',
  '.json': 'application/json', '.map': 'application/json' };
const isHashed = n => n.split('.').some(p => p.length >= 6 && /^[0-9a-f]+$/.test(p));

const server = http.createServer((req, res) => {
  try {
    const reqPath = decodeURIComponent(req.url.split('?')[0]);
    if (reqPath.includes('..')) { res.writeHead(404); return res.end(); }            // traversal guard
    let file = reqPath.replace(/^\/+/, '') || 'index.html';
    if (file === 'favicon.ico') { res.writeHead(204); return res.end(); }            // browser auto-request
    let full = path.join(DIST, file);
    const looksAsset = file.split('/').pop().includes('.');
    if (!existsSync(full) || !statSync(full).isFile()) {
      if (looksAsset) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('404'); }
      file = 'index.html'; full = path.join(DIST, file);                              // SPA fallback
    }
    const ctype = MIME[path.extname(file)] || 'application/octet-stream';
    const cache = (file === 'index.html' || file === 'manifest.json') ? 'no-cache'
      : (isHashed(file) ? 'public, max-age=31536000, immutable' : 'public, max-age=3600');
    const ae = req.headers['accept-encoding'] || '';
    let body, enc = null;
    if (/\bbr\b/.test(ae) && existsSync(full + '.br')) { body = readFileSync(full + '.br'); enc = 'br'; }
    else if (/\bgzip\b/.test(ae) && existsSync(full + '.gz')) { body = readFileSync(full + '.gz'); enc = 'gzip'; }
    else body = readFileSync(full);
    const h = { 'content-type': ctype, 'content-length': body.length, 'cache-control': cache, 'accept-ranges': 'bytes' };
    if (enc) { h['content-encoding'] = enc; h['vary'] = 'Accept-Encoding'; }
    res.writeHead(200, h); res.end(body);
  } catch (e) { res.writeHead(500); res.end(String(e)); }
});

const port = await new Promise(r => server.listen(0, '127.0.0.1', () => r(server.address().port)));
const BASE = `http://127.0.0.1:${port}`;
console.log('static server on', BASE, '(single process)');

const raw = (p, headers = {}) => new Promise((res, rej) =>
  http.get(BASE + p, { headers }, r => { const b = []; r.on('data', d => b.push(d));
    r.on('end', () => res({ status: r.statusCode, headers: r.headers, len: Buffer.concat(b).length })); }).on('error', rej));

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✅', m); } else { fail++; console.log('  ❌', m); } };

function chromePath() {
  if (process.env.CHROME_BIN && existsSync(process.env.CHROME_BIN)) return process.env.CHROME_BIN;
  for (const p of ['/usr/bin/google-chrome-stable', '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'])
    if (existsSync(p)) return p;
  return null; // fall back to Playwright's bundled browser (needs `npx playwright install`)
}
const exe = chromePath();
const browser = await chromium.launch(exe
  ? { executablePath: exe, headless: true, args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'] }
  : { headless: true });

try {
  console.log('\n[1] GET / — wasm boot & mount');
  const page = await browser.newPage();
  const cerr = [], perr = [], wasm = [];
  page.on('console', m => m.type() === 'error' && cerr.push(m.text()));
  page.on('pageerror', e => perr.push(String(e)));
  page.on('response', r => r.url().endsWith('.wasm') && wasm.push(r));
  await page.goto(BASE + '/', { waitUntil: 'networkidle' });
  await page.waitForSelector('html[data-vcsr="mounted"]', { timeout: 8000 });
  ok(await page.getAttribute('html', 'data-vcsr') === 'mounted', 'app reached mounted state');
  ok(await page.getAttribute('html', 'data-vcsr-error') === null, 'no boot error');
  ok(perr.length === 0, `no uncaught page errors (${perr.length})`);
  ok(cerr.length === 0, `no console errors (${cerr.length})`);
  ok(await page.locator('button', { hasText: '+1' }).count() > 0, 'wasm-injected +1 button present (HTML from the wasm data segment)');
  ok(await page.locator('main.counter_x1').count() > 0, 'injected <main class="counter_x1"> present');
  ok(wasm.length > 0, `core wasm fetched (${wasm.length})`);
  if (wasm.length) ok(((await wasm[0].allHeaders())['content-type'] || '').includes('application/wasm'), 'core wasm served as application/wasm');
  await page.screenshot({ path: path.join(SHOTS, '01-landing.png'), fullPage: true });
  await page.close();

  console.log('\n[2] GET /reports/42 — SPA fallback + re-mount');
  const p2 = await browser.newPage();
  const r2 = await p2.goto(BASE + '/reports/42', { waitUntil: 'networkidle' });
  ok(r2.status() === 200, `deep link 200 (${r2.status()})`);
  ok(((await r2.allHeaders())['content-type'] || '').includes('text/html'), 'served index.html (text/html)');
  await p2.waitForSelector('html[data-vcsr="mounted"]', { timeout: 8000 });
  ok(true, 'app mounted after deep-link refresh');
  await p2.screenshot({ path: path.join(SHOTS, '02-deeplink.png'), fullPage: true });
  await p2.close();

  console.log('\n[3] mobile viewport');
  const mob = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await mob.goto(BASE + '/', { waitUntil: 'networkidle' });
  await mob.waitForSelector('html[data-vcsr="mounted"]');
  ok(await mob.locator('button', { hasText: '+1' }).count() > 0, 'renders on a 390x844 mobile viewport');
  await mob.screenshot({ path: path.join(SHOTS, '03-mobile.png'), fullPage: true });
  await mob.close();

  console.log('\n[4] static-serving contract (raw HTTP)');
  const wn = wasm.length ? new URL(wasm[0].url()).pathname : '/core.9f3a1c.wasm';
  const br = await raw(wn, { 'Accept-Encoding': 'br' });
  ok(br.status === 200, `wasm 200 (${br.status})`);
  ok(br.headers['content-type'] === 'application/wasm', 'Content-Type: application/wasm');
  ok(br.headers['content-encoding'] === 'br', 'Content-Encoding: br negotiated');
  ok((br.headers['cache-control'] || '').includes('immutable'), 'immutable cache for hashed wasm');
  ok(((await raw('/')).headers['cache-control'] || '') === 'no-cache', 'index.html is no-cache');
  ok((await raw('/nope.deadbeef.wasm')).status === 404, 'missing asset → 404');
} catch (e) {
  console.error('FATAL', e); fail++;
} finally {
  await browser.close();   // kills the browser + its children
  server.close();          // closes the listener
}

console.log(`\n==== ${pass} passed, ${fail} failed ====`);
process.exit(fail === 0 ? 0 : 1);
