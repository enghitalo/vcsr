// app.js — your page's entry point. `vcsr wasm` writes this once and never
// overwrites it, so customize freely. The DOM ABI the wasm module imports lives
// in ./vcsr_host.js, which vcsr rewrites on every build.
import { boot } from './vcsr_host.js';

boot('./core.wasm');
