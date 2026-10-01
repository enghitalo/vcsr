/* vcsr WASI compat: V's C preamble includes <sys/wait.h> on every non-Windows target,
 * but wasi-libc (wasip1) does not ship it. Defer to the real header if the
 * sysroot ever gains one; otherwise provide nothing (vcsr's wasm code uses none
 * of its declarations). See runtime/wasi_compat/README.md. */
#if __has_include_next(<sys/wait.h>)
#include_next <sys/wait.h>
#endif
