# Moranduba SFU

Selective forwarding unit for Moranduba calls (Go + Pion). It has no domain or
TLS certificate: clients reach it through Nostr relays (gift wraps, outer kind
21059) and then over WebRTC. Media frames stay end-to-end encrypted; the SFU
forwards RTP. Protocol: [`docs/adr/0002-sfu-protocol.md`](../docs/adr/0002-sfu-protocol.md).

## Run with Docker

```sh
docker build -t moranduba-sfu sfu/
docker run -d --name moranduba-sfu \
  --network host \
  -e PUBLIC_IP=203.0.113.7 \
  -e RELAYS=wss://relay.example.com,wss://nos.lol \
  -v moranduba-sfu:/data \
  moranduba-sfu
docker logs moranduba-sfu
```

Open UDP `3478` (TURN/STUN) and `50000-50200` (media and TURN relays) in
the firewall. The image runs as uid 65532; a bind-mounted `/data` must be
writable by it.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `RELAYS` | `ws://localhost:7777` | Comma-separated relay URLs. Reconnects with backoff. |
| `DATA_DIR` | `/data` | Holds `key` (nsec), `state.json` (owner, allowlist, unused claim code) and `push.json` (VAPID key, members' push subscriptions). |
| `PUBLIC_IP` | auto-detected LAN IPv4 | Public IPv4 for ICE host candidates (added next to the local one) and the TURN relay address. |
| `TURN_PORT` | `3478` | Embedded TURN/STUN server, UDP. `0` picks a free port (desktop sidecar). |
| `UDP_PORT_MIN` / `UDP_PORT_MAX` | `50000` / `50200` | Port range shared by ICE and TURN relay allocations. |
| `SFU_EXIT_ON_STDIN_EOF` | unset | `1`: exit when stdin closes (desktop sidecar dies with its parent). |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. Logs go to stderr. |

## What it prints

On stdout, after the key is loaded and every relay was tried once:

```
Moranduba SFU 0.1.0
  npub:       npub1…
  pubkey:     <hex>
  claim code: XXXX-XXXX-XXXX        (or "owner: npub1…" once claimed)
  relays:     wss://… (connected: 2)
  ice host:   203.0.113.7, turn udp/3478, media udp/50000-50200
MORANDUBA_SFU {"pubkey":"<hex>","npub":"npub1…","claim_code":"XXXX-XXXX-XXXX","turn_port":3478}
```

The `MORANDUBA_SFU` line is for the desktop app: one line, JSON after the
prefix; `claim_code` is `""` once claimed. The first app that sends the claim
code becomes the owner. SIGINT and SIGTERM exit cleanly.

## Develop

```sh
cd sfu
go test ./...
SFU_RELAY_TEST=ws://localhost:7777 go test -run TestRelayIntegration ./internal/server/
DATA_DIR=./.data go run .
```

The relay test needs the dev relay from `dev/docker-compose.yml`.
