// A faithful minimal DOM for verifying the vcsr wasm host ABI in Node (V8).
// Implements exactly the operations the wasm backend imports.
export function makeDom() {
  // --- tiny HTML parser -> element tree ---
  const VOID = new Set(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr']);
  function parse(html) {
    let i = 0; const root = { tag: '#root', attrs: {}, children: [] };
    const stack = [root];
    const top = () => stack[stack.length - 1];
    while (i < html.length) {
      if (html[i] === '<') {
        if (html[i+1] === '/') { const j = html.indexOf('>', i); stack.pop(); i = j + 1; continue; }
        const j = html.indexOf('>', i);
        let inner = html.slice(i+1, j); i = j + 1;
        const selfClose = inner.endsWith('/'); if (selfClose) inner = inner.slice(0, -1);
        const sp = inner.search(/\s/);
        const tag = (sp === -1 ? inner : inner.slice(0, sp)).trim();
        const attrs = {};
        if (sp !== -1) { const re = /([\w-]+)\s*=\s*"([^"]*)"/g; let m; while ((m = re.exec(inner.slice(sp)))) attrs[m[1]] = m[2]; }
        const node = { tag, attrs, children: [] };
        top().children.push(node);
        if (!selfClose && !VOID.has(tag)) stack.push(node);
      } else {
        const j = html.indexOf('<', i); const text = html.slice(i, j === -1 ? html.length : j);
        if (text.length) top().children.push({ text });
        i = j === -1 ? html.length : j;
      }
    }
    return root.children.find(c => c.tag);  // the single root element
  }
  const clone = (n) => n.text !== undefined ? { text: n.text } : { tag: n.tag, attrs: {...n.attrs}, children: n.children.map(clone), listeners: {} };
  const elemChild = (n, idx) => { let e = 0; for (const c of n.children) { if (c.tag === undefined) continue; if (e === idx) return c; e++; } return n; };
  function serialize(n) {
    if (n.text !== undefined) return n.text;
    if (n.visible === false) return '';
    const a = Object.entries(n.attrs).map(([k,v]) => ` ${k}="${v}"`).join('');
    if (VOID.has(n.tag)) return `<${n.tag}${a}>`;
    return `<${n.tag}${a}>${n.children.map(serialize).join('')}</${n.tag}>`;
  }

  const handles = []; const ref = (o) => { handles.push(o); return handles.length - 1; };
  let templates = []; let mounted = null;
  return {
    serialize: () => mounted ? serialize(mounted) : '',
    clickFirst(tag) { // find first element with tag and a 'click' listener; return its cbIdx
      let found = null;
      (function walk(n){ if (n.tag === tag && n.listeners && 'click' in n.listeners) found = n.listeners.click; (n.children||[]).forEach(walk); })(mounted);
      return found;
    },
    env(getMem) {
      const td = new TextDecoder();
      const rd = (p,l) => td.decode(new Uint8Array(getMem().buffer, p, l));
      return {
        host_register_template: (p,l) => { templates.push(parse(rd(p,l))); return templates.length - 1; },
        host_clone: (t) => ref(clone(templates[t])),
        host_slot_at: (root, pathPtr, n) => {
          const dv = new DataView(getMem().buffer); let cur = handles[root];
          for (let k=0;k<n;k++) cur = elemChild(cur, dv.getInt32(pathPtr + k*4, true));
          return ref(cur);
        },
        host_set_text: (h,p,l) => { handles[h].children = [{ text: rd(p,l) }]; },
        host_set_attr: (h,np,nl,vp,vl) => { handles[h].attrs[rd(np,nl)] = rd(vp,vl); },
        host_set_value: (h,p,l) => { handles[h].value = rd(p,l); },
        host_set_visible: (h,v) => { handles[h].visible = !!v; },
        host_on: (h,ep,el,cb) => { (handles[h].listeners ||= {})[rd(ep,el)] = cb; },
        host_on_input: (h,cb) => { (handles[h].listeners ||= {}).input = cb; },
        host_mount: (root,sp,sl) => { mounted = handles[root]; },
      };
    },
  };
}
