#!/usr/bin/env sh
# Build this example's core.wasm (+ vcsr_host.js) from ../src. Same as running
# `vcsr wasm examples/counter/src`, without needing the CLI installed.
#
#   WASI_SDK=/opt/wasi-sdk ./build.sh
set -e
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO" && v run cmd/vcsr wasm examples/counter/src
