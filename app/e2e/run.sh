#!/usr/bin/env bash
# Builds an e2e entry point for the web and runs it in headless Chrome.
# Needs the dev stack: docker compose -f dev/docker-compose.yml up -d
# Usage, from app/: ./e2e/run.sh [e2e/call_e2e.dart]
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-e2e/call_e2e.dart}"
out="$PWD/build/e2e"
port="${PORT:-8650}"

[ -f web/mls/moranduba_mls_bg.wasm ] || ./tool/build_web_assets.sh
flutter build web --profile -t "$target" -o "$out" >/dev/null
python3 -m http.server "$port" --directory "$out" >/dev/null 2>&1 &
server=$!
trap 'kill $server' EXIT
(cd e2e && bun install --silent)
bun e2e/run.ts "http://localhost:$port/" "${ROLES:-alice,bob}"
