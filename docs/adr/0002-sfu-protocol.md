# ADR 0002: SFU signaling and media protocol

Date: 2026-11-07. Status: accepted (*provisional* kinds and message shapes).

## Context

Phase 3 adds `server` mode: every participant sends media to one Moranduba
SFU (`sfu/`, Go + Pion) instead of to each other. `host_peer` (phase 4) runs
the same binary on a member's desktop. The SFU has no domain and no TLS
certificate, so it cannot serve WebSocket signaling. It has a Nostr key pair
instead, and clients reach it through relays.

Call signaling between members already travels as MLS application messages
inside the group (`join`, `here`, `leave`, `offer`, `answer`, `switch`). The
SFU is not a group member and must not become one: it would see the group
roster and get the call key.

## Decision

### Transport to the SFU: gift wraps with an ephemeral outer kind

- A message to or from the SFU is a NIP-59 gift wrap whose outer event has
  kind **21059** (ephemeral range, so relays forward it to live subscribers
  and do not store it). The seal is kind 13, signed by the sender's real key,
  so the SFU learns the participant's pubkey from the seal signature.
- The rumor has kind **25051** and a JSON `content` (below). The rumor's
  `p` tag names the recipient.
- The SFU subscribes to `{"kinds":[21059],"#p":[<sfu pubkey>]}` on its relays
  and accepts kind 1059 too. It answers on the same relays with the same
  construction, addressed to the participant.
- Each request carries an `id` (random string); every reply echoes it as
  `reply_to`.

### Messages over Nostr

Client to SFU:

| `type` | Fields | Meaning |
|---|---|---|
| `ping` | `id` | Liveness check for mode selection (answer within 3 s). |
| `claim` | `id`, `code` | First start prints a one-time code. The first valid claim makes the sender the owner. |
| `allow` | `id`, `pubkeys` | Owner only. Replaces the allowlist (owner always allowed). |
| `join` | `id`, `room`, `sdp` | Offer for one call. `room` is the call id. |

SFU to client:

| `type` | Fields |
|---|---|
| `pong` | `reply_to`, `owner` (bool: sender is owner), `allowed` (bool), `ice_servers` (list of `{urls, username?, credential?}`), `version` |
| `claimed` | `reply_to` |
| `allowed` | `reply_to`, `count` |
| `answer` | `reply_to`, `room`, `sdp` |
| `error` | `reply_to`, `message` |

The client sends `ping` before `join` and builds its peer connection with the
`ice_servers` from `pong`, which include the SFU's embedded TURN server with
short-lived credentials (TURN REST style: username `<unix expiry>:<pubkey>`,
password `base64(HMAC-SHA1(secret, username))`).

### After the bootstrap: one DataChannel

The client's offer includes a negotiated DataChannel labelled `moranduba`
(`id` 0, `negotiated: true`, ordered). Everything after the first answer
goes over it as JSON:

| Direction | `type` | Fields |
|---|---|---|
| SFU → client | `offer` | `sdp`: SFU-initiated renegotiation when tracks come or go |
| client → SFU | `answer` | `sdp` |
| SFU → client | `speakers` | `pubkeys`: active speakers, loudest first |
| client → SFU | `layer` | `pubkey`, `rid` (`q`, `h` or `f`): preferred simulcast layer for that publisher |
| client → SFU | `pin` | `pubkeys`: always forward these publishers' video to me |

The client never renegotiates on its own: it offers one audio sender and one
video sender (simulcast `q`/`h`/`f`, VP8) up front and swaps camera, screen
or nothing into the video sender with `replaceTrack`.

### Media

- Codecs: Opus and VP8 only, so the SFU never needs to parse other payloads.
- Every remote track the SFU adds uses the publisher's pubkey as the stream
  id (msid), so clients map tracks to participants without extra messages.
- Frames stay encrypted end to end with the MLS-derived call key
  (FrameCryptor). The SFU forwards RTP and reads only RTP headers and the
  audio level header extension (RFC 6464).
- Forwarding policy: audio from the 3 loudest publishers; video from the 6
  most recent active speakers plus the publishers each client pins. The SFU
  cannot tell a screen share from a camera (frames are encrypted), so clients
  pin screen sharers, which they know from the group's call signals. A newly
  selected video stream gets a PLI so a keyframe arrives quickly.
- Simulcast: default layer `h`; `layer` messages override per publisher.
  Layer switches request a keyframe and keep sequence numbers continuous.

### Identity, ownership, storage

- First start writes `/data/key` (nsec) and `/data/state.json` (owner,
  allowlist, unused claim code) and prints the npub and claim code.
- Strangers get `error: not allowed` on `join`. Even if one got in, frames
  stay encrypted.

### In the group

A group's `preferred_sfu` (npub) travels as a group signal
`{"t":"sfu","sfu":{"npub","set_at"}}`, newest `set_at` wins, announced again
on new epochs like the disappearing-message timer. The owner's app keeps the
SFU allowlist equal to the members of every group that prefers that SFU.

## Consequences

- Relays see that some pubkey talks to the SFU's pubkey, not the content.
- The SFU needs no certificate, domain or open signaling port: only UDP for
  media and TURN.
- Ephemeral outer events are lost if the SFU is offline. Clients treat a
  missing `pong` within 3 s as "server unavailable" and fall back to mesh.
