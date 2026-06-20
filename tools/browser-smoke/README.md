# browser-smoke — run a vcsr bundle in a real browser

Phase 10 proves vcsr's `dist/` serves correctly at the HTTP-bytes level
(socket-free, via vanilla's `static_assets.respond`). This smoke test goes one
step further: it loads that `dist/` in a **real browser** and asserts the
WebAssembly module actually instantiates, mounts, and renders.

It's the live proof of the core thesis: `index.html` ships an **empty
`<body>`** → the loader streaming-instantiates `core.<hash>.wasm` → the module
hands its **embedded HTML skeleton** (verbatim bytes from the wasm data segment)
across the host boundary → the host injects it into the DOM.

Two harnesses:

- **`browser-smoke.mjs`** — the minimal `testdata/fixture-app` (18 checks).
- **`dashboard-smoke.mjs`** — the complex `testdata/dashboard-app` ("vcsr
  console"): a C→wasm32 app on the integer-handle DOM runtime exercising
  reactive state, events, computed values, list rendering, **async fetch**,
  **localStorage** persistence, conditional views, and light/dark theming —
  driven with real clicks/typing (14 checks). Screenshots in
  `screenshots/dashboard/`.

## Run

```sh
cd tools/browser-smoke
npm install                 # installs Playwright (the run uses your system Chrome)
node browser-smoke.mjs      # serves ../../testdata/fixture-app/dist, drives Chrome, asserts, screenshots
```

Exit code `0` means all checks passed. Screenshots land in `screenshots/`.

- `VCSR_DIST=/abs/path/to/dist` — point it at a different built bundle.
- `CHROME_BIN=/usr/bin/chromium` — choose the browser binary. If none is found
  it falls back to Playwright's bundled Chromium (`npx playwright install chromium`).

Build the fixture bundle first if `dist/` is missing — anything that calls
`bundle.build('testdata/fixture-app', release: true)`.

## What it checks (18)

| Scenario | Asserts |
|---|---|
| `GET /` | reaches `html[data-vcsr="mounted"]`; no page/console errors; the wasm-injected `+1` button and `<main class="counter_x1">` are present; `core.*.wasm` fetched as `application/wasm` |
| `GET /reports/42` | 200 `text/html` (SPA fallback to index.html); app re-mounts on refresh |
| 390×844 | renders on a mobile viewport |
| raw HTTP | wasm `application/wasm`; `Content-Encoding: br` negotiated; immutable cache for hashed assets; `index.html` is `no-cache`; missing asset → 404 |

## Why it's built this way (safety)

This harness is **one Node process** that holds *both* the static file server
(an event-driven `http.createServer` — idles at ~0% CPU) *and* the Playwright
driver, plus a hard 60-second self-timeout. So at any instant there is exactly
**one server and one browser**, and both die when the process exits.

It deliberately does **not** use vanilla's `http_server` to serve the bundle for
this test: that server spawns a busy-polling worker **per CPU core**, and
launching it repeatedly (or not reaping it) pins every core. The HTTP-level
serving contract is already covered, socket-free, by phase 10.

## Caveat

The fixture's `core.wasm` is the smallest possible browser-ABI module, so the
rendered DOM is just `<main><h1></h1><button>+1</button></main>` — visually
sparse on purpose. The point is the path (wasm → host → DOM), not the pixels.
V cannot yet emit a browser-ready wasm module, so this is a prebuilt browser-ABI
fixture; see [docs/WASM-PATHS-ANALYSIS.md](../../docs/WASM-PATHS-ANALYSIS.md).
