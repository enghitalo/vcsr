/* vcsr WASI compat: V's C preamble includes <setjmp.h> unconditionally, but
 * wasi-libc's setjmp.h is an #error unless wasm exception handling is enabled.
 * V only *calls* setjmp for programs that use recover(), which vcsr's wasm
 * runtime does not, so the header is safe to skip. See README.md here. */
#if defined(__wasm_exception_handling__)
#include_next <setjmp.h>
#endif
