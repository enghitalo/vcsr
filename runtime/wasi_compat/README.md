# runtime/wasi_compat — headers V expects that WASI lacks

`vcsr wasm` (and the `build.sh` recipes) compile V's generated C with
wasi-sdk's clang, passing `-I runtime/wasi_compat`. V's C preamble includes a
fixed set of POSIX headers on every non-Windows target, and wasi-libc
(`wasm32-wasip1`) is missing or rejects a few of them:

| header        | in wasi-libc            | shim here                                      |
|---------------|-------------------------|------------------------------------------------|
| `netdb.h`     | missing                 | empty unless a real one exists (`#include_next`) |
| `termios.h`   | missing                 | same                                           |
| `sys/wait.h`  | missing                 | same                                           |
| `setjmp.h`    | `#error` without wasm EH | empty unless `__wasm_exception_handling__`     |

`sys/mman.h`, `signal.h` and `sys/resource.h` are handled by wasi-libc's own
emulation libraries instead (`-D_WASI_EMULATED_{MMAN,SIGNAL,PROCESS_CLOCKS}` +
`-lwasi-emulated-*`).

The link also passes `-Wl,--no-stack-first -Wl,--global-base=65536`: V's
`vmemcpy`/`vmemmove`/`vmemset`/`vmemcmp` treat any pointer `<= 0xFFFF` as null
and silently do nothing, but on wasm32 the default layout puts the shadow stack
in the first 64 KiB — so every array literal (copied from a stack temporary)
came out zeroed. Starting static data at 64 KiB, with the stack after it, keeps
every address above that threshold.
