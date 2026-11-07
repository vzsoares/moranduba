#!/usr/bin/env bash
# Builds the MLS engine for the browser into web/mls/. Run from app/.
# Needs: rustup, and wasm-bindgen-cli matching rust/Cargo.toml:
#   rustup component add llvm-tools --toolchain 1.98.1
#   cargo install wasm-bindgen-cli --version 0.2.130 --locked
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

# secp256k1 is C: the system ar on macOS can't index wasm objects.
sysroot="$(cd rust && rustc --print sysroot)"
host="$(cd rust && rustc -vV | sed -n 's/^host: //p')"
export AR_wasm32_unknown_unknown="$sysroot/lib/rustlib/$host/bin/llvm-ar"

profile="${1:-wasm}"
(cd rust && cargo build --target wasm32-unknown-unknown --profile "$profile")
dir="$profile"
[ "$profile" = dev ] && dir=debug
wasm-bindgen \
  --target web \
  --no-typescript \
  --out-dir web/mls \
  "rust/target/wasm32-unknown-unknown/$dir/moranduba_mls.wasm"
ls -lh web/mls
