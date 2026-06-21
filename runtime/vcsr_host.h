#ifndef VCSR_HOST_H
#define VCSR_HOST_H
// Host (JS) imports the wasm rendering backend calls — the vcsr DOM ABI. DOM nodes
// cross as integer HANDLES (an index into a host-side table); strings as (ptr,len)
// into shared linear memory. V emits no prototype for `C.` functions, so this
// header supplies them with import_module/import_name attributes (clean
// `(import "env" "...")`, no --allow-undefined). Pair with -I <repo>/runtime.
#define VCSR_IMPORT(name) __attribute__((import_module("env"), import_name(#name)))

// element creation / template
VCSR_IMPORT(host_register_template) int  host_register_template(const unsigned char* html, int len);
VCSR_IMPORT(host_clone)             int  host_clone(int tpl);
VCSR_IMPORT(host_slot_at)           int  host_slot_at(int root, const int* path, int n);

// per-node mutations (the reactive patches)
VCSR_IMPORT(host_set_text)    void host_set_text(int node, const unsigned char* ptr, int len);
VCSR_IMPORT(host_set_attr)    void host_set_attr(int node, const unsigned char* np, int nl, const unsigned char* vp, int vl);
VCSR_IMPORT(host_set_value)   void host_set_value(int node, const unsigned char* ptr, int len);
VCSR_IMPORT(host_set_visible) void host_set_visible(int node, int visible);

// events: register a wasm callback index; host calls vcsr_dispatch / vcsr_dispatch_input back
VCSR_IMPORT(host_on)       void host_on(int node, const unsigned char* ev, int el, int cb_idx);
VCSR_IMPORT(host_on_input) void host_on_input(int node, int cb_idx);

// mount the cloned root into document.querySelector(sel)
VCSR_IMPORT(host_mount) void host_mount(int root, const unsigned char* sel, int len);

#endif
