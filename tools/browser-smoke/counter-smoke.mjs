// counter-smoke.mjs — drive the compiled-V counter wasm in a REAL browser.
//
// Serves examples/counter/wasm/ (with Content-Type: application/wasm) and loads it
// in headless Chromium: asserts the wasm-built UI renders, then clicks the real
// +1 button and asserts the bound <h1>(count)/<span>(doubled) re-patch reactively.
//
//   cd tools/browser-smoke && node counter-smoke.mjs
import http from 'node:http';
import { readFileSync, existsSync, statSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// VCSR_WASM_DIR lets this drive any `vcsr wasm` output dir (e.g. one with the
// DEFAULT emitted app.js/index.html); defaults to the counter example.
const DIR = process.env.VCSR_WASM_DIR || path.resolve(HERE, '../../examples/counter/wasm');
const SHOTS = path.join(HERE, 'screenshots', 'counter');
if (!existsSync(path.join(DIR, 'core.wasm'))) { console.error(`No core.wasm in ${DIR} — run ./build.sh first.`); process.exit(1); }
mkdirSync(SHOTS, { recursive: true });
setTimeout(() => { console.error('!! safety timeout (60s)'); process.exit(2); }, 60_000).unref();

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm' };
const server = http.createServer((req, res) => {
  const p = decodeURIComponent(req.url.split('?')[0]);
  let file = p.replace(/^\/+/, '') || 'index.html';
  const full = path.join(DIR, file);
  if (!existsSync(full) || !statSync(full).isFile()) { res.writeHead(404); return res.end('404'); }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream' });
  res.end(readFileSync(full));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch();
const page = await browser.newPage();
const logs = []; page.on('console', m => logs.push(m.text())); page.on('pageerror', e => logs.push('PAGEERROR ' + e.message));
let ok = false;
try {
  await page.goto(base, { waitUntil: 'load' });
  await page.waitForSelector('[data-vcsr="mounted"]', { timeout: 10_000 });
  const h1 = () => page.textContent('#app h1');
  const span = () => page.textContent('#app .muted span');

  const before = [await h1(), await span()];
  await page.screenshot({ path: path.join(SHOTS, 'before.png') });
  const btn = page.locator('#app button');
  await btn.click(); await page.waitForFunction(() => document.querySelector('#app h1')?.textContent === '1', { timeout: 5_000 });
  const after1 = [await h1(), await span()];
  await btn.click(); await btn.click();
  await page.waitForFunction(() => document.querySelector('#app h1')?.textContent === '3', { timeout: 5_000 });
  const after3 = [await h1(), await span()];
  await page.screenshot({ path: path.join(SHOTS, 'after3.png') });

  console.log('initial   count/doubled =', before);
  console.log('after x1  count/doubled =', after1);
  console.log('after x3  count/doubled =', after3);
  ok = before[0] === '0' && before[1] === '0' && after1[0] === '1' && after1[1] === '2' && after3[0] === '3' && after3[1] === '6';
} catch (e) {
  console.error('FAILED:', e.message); console.error('page logs:', logs.join(' | '));
} finally {
  await browser.close(); server.close();
}
console.log(ok
  ? '\n✅ PASS — the compiled-V vcsr counter runs in real Chromium: clicking the wasm-rendered +1 button re-patches <h1>=count and <span>=doubled (0→1→3 / 0→2→6) via the host DOM FFI.'
  : '\n❌ FAIL');
process.exit(ok ? 0 : 1);
