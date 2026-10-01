// app.js — the template-basics page's entry point. The DOM ABI the wasm module imports
// lives in ./vcsr_host.js, which `vcsr wasm` rewrites on every build.
import { boot } from './vcsr_host.js';

boot('./core.wasm');
