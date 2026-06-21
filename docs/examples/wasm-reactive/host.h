#ifndef VCSR_HOST_H
#define VCSR_HOST_H
// Declares the host import V calls via `fn C.host_set_text`. The import
// attributes give wasm-ld a clean `(import "env" "host_set_text" ...)` with no
// --allow-undefined needed. V emits no prototype for `C.` functions, so this
// header supplies one (pulled in via `#include "host.h"` at the top of app.v).
__attribute__((import_module("env"), import_name("host_set_text")))
void host_set_text(const unsigned char* ptr, int len);
#endif
