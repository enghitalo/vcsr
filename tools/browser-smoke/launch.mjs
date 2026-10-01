// launch.mjs — the one place the smoke scripts pick and launch a browser.
//
// Prefers an installed Chrome/Chromium (so `npm ci` is all the setup needed),
// honoring CHROME_BIN; falls back to Playwright's bundled browser, which needs
// `npx playwright install chromium`.
import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

export function chromePath() {
  if (process.env.CHROME_BIN && existsSync(process.env.CHROME_BIN)) return process.env.CHROME_BIN;
  for (const p of ['/usr/bin/google-chrome-stable', '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'])
    if (existsSync(p)) return p;
  return null;
}

export function launchChrome() {
  const exe = chromePath();
  return chromium.launch(exe
    ? { executablePath: exe, headless: true, args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'] }
    : { headless: true });
}
