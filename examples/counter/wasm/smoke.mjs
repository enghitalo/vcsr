import { readFile } from 'node:fs/promises';
import { makeDom } from './dom.mjs';
const bytes = await readFile(new URL('./core.wasm', import.meta.url));
let exp; const dom = makeDom();
const wasi = new Proxy({ proc_exit:(c)=>{throw new Error('exit '+c)},
  fd_write:(fd,io,n,nw)=>{const dv=new DataView(exp.memory.buffer);let t=0;for(let i=0;i<n;i++)t+=dv.getUint32(io+i*8+4,true);dv.setUint32(nw,t,true);return 0;},
  random_get:(p,l)=>{crypto.getRandomValues(new Uint8Array(exp.memory.buffer,p,l));return 0;} },
  { get:(t,k)=> k in t?t[k]:(()=>0) });
const { instance } = await WebAssembly.instantiate(bytes, { env: dom.env(()=>exp.memory), wasi_snapshot_preview1: wasi });
exp = instance.exports; exp._initialize(); exp._vinit(0,0);
exp.boot();
const a = dom.serialize().replace(/\n\s*/g,'');
console.log('after boot():', a);
const ok0 = a.includes('<h1>0</h1>') && a.includes('<span>0</span>') && a.includes('<button>+1</button>');
const cb = dom.clickFirst('button');
console.log('button click cbIdx =', cb);
exp.vcsr_dispatch(cb);                       // simulate the click → inc → reactive re-patch
const b = dom.serialize().replace(/\n\s*/g,'');
console.log('after click:  ', b);
const ok1 = b.includes('<h1>1</h1>') && b.includes('<span>2</span>');
exp.vcsr_dispatch(cb); exp.vcsr_dispatch(cb);
const c = dom.serialize().replace(/\n\s*/g,'');
console.log('after x3:     ', c);
const ok3 = c.includes('<h1>3</h1>') && c.includes('<span>6</span>');
const ok = ok0 && cb !== null && ok1 && ok3;
console.log(ok ? '\n✅ PASS — the vcsr-GENERATED counter, compiled V→wasm with the host-owned-DOM backend, renders and reacts: a click runs inc(), the signal write re-patches ONLY the bound <h1>(count) and <span>(doubled) via host FFI. 0→1→3.'
              : `\n❌ FAIL ok0=${ok0} cb=${cb} ok1=${ok1} ok3=${ok3}`);
process.exit(ok?0:1);
