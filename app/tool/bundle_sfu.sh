#!/usr/bin/env bash
# Puts the SFU next to the app executable, for hosting calls (host peer).
# Run after `flutter build <platform>`, from app/:
#   ./tool/bundle_sfu.sh macos|linux|windows [release|debug|profile]
# SIGN_IDENTITY signs the macOS helper; ad hoc ("-") by default.
set -euo pipefail
cd "$(dirname "$0")/.."
platform="$1"
mode="${2:-release}"
Mode="$(tr '[:lower:]' '[:upper:]' <<<"${mode:0:1}")${mode:1}"
sfu="$PWD/../sfu"

build() {
  (cd "$sfu" && CGO_ENABLED=0 GOOS="$1" GOARCH="$2" \
    go build -trimpath -ldflags="-s -w" -o "$3" .)
}

case "$platform" in
  macos)
    app="build/macos/Build/Products/$Mode/moranduba.app"
    out="$app/Contents/MacOS/moranduba-sfu"
    tmp="$(mktemp -d)"
    build darwin arm64 "$tmp/arm64"
    build darwin amd64 "$tmp/amd64"
    lipo -create -output "$out" "$tmp/arm64" "$tmp/amd64"
    rm -rf "$tmp"
    # A sandboxed app may only spawn helpers that inherit its sandbox.
    codesign --force --options runtime \
      --entitlements macos/Runner/Sidecar.entitlements \
      --sign "${SIGN_IDENTITY:--}" "$out"
    codesign --force --deep --preserve-metadata=entitlements \
      --sign "${SIGN_IDENTITY:--}" "$app"
    ;;
  linux)
    arch="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')"
    goarch="$(sed 's/x64/amd64/' <<<"$arch")"
    out="build/linux/$arch/$mode/bundle/moranduba-sfu"
    build linux "$goarch" "$out"
    ;;
  windows)
    out="build/windows/x64/runner/$Mode/moranduba-sfu.exe"
    build windows amd64 "$out"
    ;;
  *)
    echo "usage: $0 macos|linux|windows [release|debug|profile]" >&2
    exit 2
    ;;
esac
echo "bundled $out"
