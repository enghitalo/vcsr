#!/usr/bin/env sh
# Compile the vcsr counter component to a browser-ABI core.wasm via Path 2
# (v -cc clang + wasi-sdk) with the host-owned-DOM backend (-d wasm_browser).
# This is the recipe `vcsr wasm` automates. core.wasm is a gitignored build
# artifact — run this (or `vcsr wasm`) before the smoke / opening index.html.
#
#   WASI_SDK=/opt/wasi-sdk ./build.sh
set -e
cd "$(dirname "$0")"
REPO="$(cd ../../.. && pwd)"
WASI_SDK="${WASI_SDK:-/opt/wasi-sdk}"
[ -d "$WASI_SDK/share/wasi-sysroot" ] || { echo "set WASI_SDK to an unpacked wasi-sdk (got '$WASI_SDK')"; exit 1; }

# 1) V -> C, with -d wasm_browser so the runtime compiles its host-owned-DOM
#    backend (map-free, closure-free) instead of the native mock tree.
( cd "$REPO" && v -d wasm_browser -d no_backtrace -d no_getpid -d no_gettid -d no_segfault_handler \
  -enable-globals -cc clang -gc none -o examples/counter/wasm/core.c examples/counter/src/ )

# 2) C -> wasm. Reactor model; -I runtime for vcsr_host.h (the DOM-ABI prototypes).
"$WASI_SDK/bin/clang" --sysroot="$WASI_SDK/share/wasi-sysroot" --target=wasm32-wasip1 \
  -mexec-model=reactor -Wl,--no-entry -Wl,--export-all -Wl,--strip-all \
  -I "$REPO/runtime" \
  -D_WASI_EMULATED_MMAN -lwasi-emulated-mman \
  -D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal \
  -O3 -o core.wasm core.c

rm -f core.c
echo "built core.wasm ($(wc -c < core.wasm) bytes)"
command -v wasm-validate >/dev/null && wasm-validate core.wasm && echo "valid"
