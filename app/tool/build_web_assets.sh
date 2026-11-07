#!/usr/bin/env bash
# Builds browser-only assets: the MLS engine (web/mls/) and the WebRTC
# frame-encryption worker (web/e2ee.worker.dart.js). Run from app/.
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

# The worker must match the dart_webrtc version the app resolves.
webrtc="$(sed -n 's#.*"rootUri": "\(.*dart_webrtc-[^"]*\)".*#\1#p' \
  .dart_tool/package_config.json | sed 's#^file://##')"
dart compile js -O2 \
  --packages=.dart_tool/package_config.json \
  -o web/e2ee.worker.dart.js \
  "$webrtc/lib/src/e2ee.worker/e2ee.worker.dart"
rm -f web/e2ee.worker.dart.js.deps web/e2ee.worker.dart.js.map
ls -lh web/mls web/e2ee.worker.dart.js
