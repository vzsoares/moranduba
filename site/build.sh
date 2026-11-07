#!/usr/bin/env bash
# Builds the deployable site into build/site: this landing page at /, the
# web app at /app/. MORANDUBA_RELAYS and MORANDUBA_BLOSSOM bake in defaults.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/site"

cd "$root/app"
./tool/build_web_mls.sh
args=(--release --base-href /app/)
if [ -n "${MORANDUBA_RELAYS:-}" ]; then
  args+=("--dart-define=MORANDUBA_RELAYS=$MORANDUBA_RELAYS")
fi
if [ -n "${MORANDUBA_BLOSSOM:-}" ]; then
  args+=("--dart-define=MORANDUBA_BLOSSOM=$MORANDUBA_BLOSSOM")
fi
flutter build web "${args[@]}"

rm -rf "$out"
mkdir -p "$out"
cp -R "$root/site/." "$out/"
rm "$out/build.sh"
cp -R build/web "$out/app"
echo "Site ready in $out"
