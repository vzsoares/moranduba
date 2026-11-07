#!/usr/bin/env bash
# Runs tool/wasm_lifecycle.cjs against a Node build of the wasm engine.
# Run from app/ after tool/build_web_assets.sh.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
wasm-bindgen \
  --target nodejs \
  --no-typescript \
  --out-dir "$out" \
  rust/target/wasm32-unknown-unknown/wasm/moranduba_mls.wasm
node tool/wasm_lifecycle.cjs "$out/moranduba_mls.js"
