// example.mjs — build-agnostic browser check + screenshot for one example.
//
//   node example.mjs ../../examples/<name>          # check + write <name>/screenshot.png
//   node example.mjs ../../examples/<name> --no-shot
//
// Serves <example>/wasm (what `vcsr wasm <example>/src` emits) from this one Node
// process (same safety design as browser-smoke.mjs: one server + one browser,
// hard timeout), waits for the app to mount, then runs <example>/check.mjs if it
// exists: `export default async (page, { ok, shot }) => { ... }` drives the page
// and asserts with ok(cond, msg). Any page error or console error fails the run.
// The final state is captured to <example>/screenshot.png for the README.
import http from 'node:http';
import { readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { launchChrome } from './launch.mjs';

const EX = path.resolve(process.argv[2] || '');
const DIR = path.join(EX, 'wasm');
const SHOT = !process.argv.includes('--no-shot');
if (!existsSync(path.join(DIR, 'core.wasm'))) {
  console.error(`No ${DIR}/core.wasm — build it first: vcsr wasm ${path.join(EX, 'src')}`);
  process.exit(1);
}
setTimeout(() => { console.error('!! safety timeout (60s)'); process.exit(2); }, 60_000).unref();

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.wasm': 'application/wasm', '.png': 'image/png', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  if (rel === 'favicon.ico') { res.writeHead(204); return res.end(); }   // browser auto-request
  const full = path.join(DIR, rel);
  if (rel.includes('..') || !existsSync(full) || !statSync(full).isFile()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream' });
  res.end(readFileSync(full));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✅', m); } else { fail++; console.log('  ❌', m); } };
const browser = await launchChrome();
const page = await browser.newPage({ viewport: { width: 900, height: 640 }, deviceScaleFactor: 2 });
const errors = [];
page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
// README screenshots frame the mounted app (+ a margin), not the whole viewport
const shot = async (name) => {
  const box = await page.locator('#app').boundingBox();
  const m = 24;
  const clip = box && box.width > 0 && box.height > 0
    ? { x: Math.max(0, box.x - m), y: Math.max(0, box.y - m), width: box.width + 2 * m, height: box.height + 2 * m }
    : undefined;
  return page.screenshot({ path: path.join(EX, name), clip });
};
try {
  console.log(`${path.basename(EX)}:`);
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForFunction(() => document.documentElement.dataset.vcsr === 'mounted'
    || document.documentElement.dataset.vcsrError, null, { timeout: 15_000 });
  ok(!(await page.evaluate(() => document.documentElement.dataset.vcsrError)), 'wasm booted and mounted');
  const check = path.join(EX, 'check.mjs');
  if (existsSync(check)) await (await import(pathToFileURL(check).href)).default(page, { ok, shot });
  ok(errors.length === 0, `no page/console errors${errors.length ? ': ' + errors.join(' | ') : ''}`);
  if (SHOT) { await shot('screenshot.png'); console.log('  📸', path.join(path.relative(process.cwd(), EX), 'screenshot.png')); }
} catch (e) {
  fail++; console.log('  ❌', e.message);
} finally {
  await browser.close(); server.close();
}
console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
