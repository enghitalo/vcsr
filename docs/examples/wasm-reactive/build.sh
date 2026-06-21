#!/usr/bin/env sh
# Build the closure-free reactive PoC to browser-ABI wasm (Path 2: v -cc clang +
# wasi-sdk). Reproduces the exact recipe Gate 1 needs. Re-run only if you edit
# app.v. app.wasm is a gitignored build artifact — run this before `node harness.mjs`.
#
#   WASI_SDK=/opt/wasi-sdk ./build.sh      # or ~/wasi-sdk-25.0-x86_64-linux
set -e
cd "$(dirname "$0")"
WASI_SDK="${WASI_SDK:-/opt/wasi-sdk}"
[ -d "$WASI_SDK/share/wasi-sysroot" ] || { echo "set WASI_SDK to an unpacked wasi-sdk (got '$WASI_SDK')"; exit 1; }

# 1) V -> C. The -d flags drop Linux-only runtime bits absent on WASI; -gc none
#    avoids the GC; -enable-globals because the reactive core uses a global.
v -d no_backtrace -d no_getpid -d no_gettid -d no_segfault_handler \
  -enable-globals -cc clang -gc none -o app.c app.v

# 2) C -> wasm. Reactor model (exports _initialize); export all (V marks exports
#    visibility=default); strip; emulate mman/signal libc bits.
"$WASI_SDK/bin/clang" --sysroot="$WASI_SDK/share/wasi-sysroot" --target=wasm32-wasip1 \
  -mexec-model=reactor -Wl,--no-entry -Wl,--export-all -Wl,--strip-all \
  -D_WASI_EMULATED_MMAN -lwasi-emulated-mman \
  -D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal \
  -O3 -o app.wasm app.c

rm -f app.c
echo "built app.wasm ($(wc -c < app.wasm) bytes)"
command -v wasm-validate >/dev/null && wasm-validate app.wasm && echo "valid"
