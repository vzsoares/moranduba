#!/usr/bin/env bash
# Puts the dev stack (web app, relay, Blossom) on public HTTPS URLs through
# Cloudflare quick tunnels, so phones and other machines can join in.
# No account needed. Needs cloudflared, docker, python3. Ctrl+C stops it all.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
port="${PORT:-8620}"
logs="$(mktemp -d)"
pids=()

cleanup() {
  [ "${#pids[@]}" -gt 0 ] && kill "${pids[@]}" 2>/dev/null
  rm -rf "$logs"
}
trap cleanup EXIT INT TERM

start_tunnel() {
  cloudflared tunnel --no-autoupdate --url "$2" >"$logs/$1.log" 2>&1 &
  pids+=("$!")
}

# Quick tunnels print their random URL to the log once registered.
url_of() {
  for _ in $(seq 60); do
    local url
    url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$logs/$1.log" \
      | head -1 || true)"
    if [ -n "$url" ]; then
      echo "$url"
      return
    fi
    sleep 1
  done
  echo "No tunnel URL for $1:" >&2
  cat "$logs/$1.log" >&2
  exit 1
}

docker compose -f "$root/dev/docker-compose.yml" up -d
start_tunnel relay http://localhost:7777
start_tunnel blossom http://localhost:8800
start_tunnel app "http://localhost:$port"
relay="$(url_of relay)"
blossom="$(url_of blossom)"
app="$(url_of app)"

cd "$root/app"
./tool/build_web_assets.sh >/dev/null
flutter build web \
  --output "$root/build/tunnel" \
  --dart-define=MORANDUBA_RELAYS="wss://${relay#https://}" \
  --dart-define=MORANDUBA_BLOSSOM="$blossom"
python3 -m http.server "$port" --directory "$root/build/tunnel" \
  >"$logs/http.log" 2>&1 &
pids+=("$!")

cat <<EOF

  App      $app
  Relay    wss://${relay#https://}
  Blossom  $blossom

Open the app URL on any device. New tunnel URLs need a few seconds to
resolve. Each browser or device is its own identity. Ctrl+C to stop.
EOF
wait
