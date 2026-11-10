# ADR 0003: Calls without a TURN server

Date: 2026-11-09. Status: accepted.

## Context

A `server` call always connects: the VPS SFU has a public IP and an
embedded TURN server. `mesh` and `host_peer` have nothing like it. STUN
covers most home networks, but roughly 10–20% of peer pairs sit behind
symmetric NATs, carrier-grade NAT or UDP-blocking firewalls and never
find a direct path. In `host_peer` a member who cannot reach the host
already makes the whole call fall back to mesh (presence carries the
mode), so the gap that matters is a mesh pair that cannot connect.

Constraints from the rest of the design:

- No accounts, nothing the publisher has to run or pay for.
- Frames stay encrypted with the MLS call key end to end; nothing outside
  the group sees media.
- Mode switching is make before break, and mesh links must not need
  renegotiation (offers carry every candidate, no trickle).

## Options

| | Public TURN service | Relay through a member | User or community TURN list |
|---|---|---|---|
| Who runs it | A company (Metered, Cloudflare, Twilio) | Nobody extra: a member already in the call | Whoever the user trusts: their own coturn, a friend, a provider |
| Setup | Publisher account and API key, credentials shipped in a public open-source client (abused within days) or minted by a backend we would have to run | None | User pastes URL, username and password |
| Cost | Paid per GB after a small free tier, on the publisher | Upload of the relaying member | On whoever runs the server |
| Privacy | One third party sees every caller's IP, timing and bitrate, for every group | The relay already has direct links to both peers, so it learns no new IP; it is a call member and already decrypts both peers' media | The TURN operator sees the IPs of calls that use it |
| E2EE | Intact (TURN forwards SRTP carrying encrypted frames) | Intact: decrypted only on a member that holds the call key, re-encrypted with the same key before it leaves | Intact |
| Reliability | High, as long as the account stays paid and the key valid | Needs a third participant with direct links to both; useless in a two-person call | As good as the server; works in two-person calls |
| Quality | Native | The relay decodes and re-encodes: one more generation of compression, some added delay, extra CPU on the relay | Native |

A "community list" baked into the app was considered too: free, credential-less
TURN servers are rare, short-lived and attractive to abuse, and a list we
publish makes us answerable for their uptime and logging. Users can still
add any such server themselves.

## Decision

Two layers, both without any account or server of ours:

1. **Relay through a member (default).** When a mesh pair fails ICE, a
   third participant with working direct links to both forwards their
   media over separate relay links.
2. **TURN list (fallback, user configured).** Each device can list TURN
   servers (Profile > Relays and file servers). They join the ICE servers of
   every link: mesh, relay and SFU. This covers two-person calls and pairs
   with no common neighbour. Empty by default.

A public TURN service is not built in. Someone who has one pastes its
credentials into the TURN list.

### Detecting a failed pair

- A mesh link counts as failed when its connection state reaches `failed`,
  or when it is not `connected` 20 s after it was created.
- The dialer (lower pubkey) redials with backoff: at once, then 5, 10, 20,
  40, 60 s. Both sides keep the peer in their failed set until a direct link
  connects.
- In mesh, presence (`join`/`here`) carries the sender's link report:
  `links` (participants with a connected direct link) and `failed`. A
  change in either triggers an extra `here` within a second.

### Choosing the relay

Every participant runs the same pure function over the reports it has
heard (its own included), so no extra coordination message is needed:

- A pair `(a, b)` needs a relay when either lists the other as failed and
  both sent a report (clients without relay support never get relay links).
- Candidates are participants `c` whose own report lists both `a` and `b`
  as connected.
- The relay is the candidate with the highest `fnv1a(pair + c)`
  (rendezvous hashing, `pair` being the two pubkeys in order). Pairs spread
  over members instead of loading the lowest pubkey, and a member joining
  moves only the pairs it now wins.

### Relay links

- The relay opens one send-only peer connection to each end, carrying the
  other end's audio and video: tracks it already receives on its direct
  link, sent with `addTrack`. On the web it sends a clone, so the relay's
  own deafen or per-person mute (which disable the received track) does not
  silence what it forwards; native flutter_webrtc cannot clone, so there
  the received track itself goes out.
- Signals: `relay_offer` and `relay_answer` (MLS application messages like
  `offer`/`answer`), with `origin` naming whose media the link carries.
  Older clients ignore the unknown types.
- The relay's sender cryptor encrypts with the shared call key; the
  receiving end attaches its receiver cryptor as for any link. Plaintext
  exists only inside the relay's process, which holds the key anyway.
- An end shows the direct stream once the direct link is connected, else the
  relay stream. A direct redial in progress never replaces a working relay
  stream, so recovery is make before break too.
- A relay job ends when the pair no longer needs it or the relay loses a
  direct link to either end; the relay closes its links and the ends fall
  back to whatever is connected. The plan is recomputed on every report, so
  a relay that leaves is replaced by the next candidate.
- Link stats name the relay (`via`) so the UI and tests can tell.
- While a planned relay is coming up the end shows the peer as `relaying`;
  it shows `failed`, with the TURN hint, only when no member can relay or
  the relay link failed or did not connect within 20 s.

## Consequences

- Most failing pairs in calls of three or more recover with no setup.
- A relay member's upload grows by about two extra streams per pair it
  relays, and its CPU by one decode and encode per forwarded track. The
  mesh video cap still bounds the total.
- Relayed video goes through a second encoder: lower quality and some
  added latency compared with a direct link.
- Two-person calls behind hard NATs still need a TURN server or a call
  server. The UI shows the peer as failed; adding a TURN server or a call
  server fixes it.
- Presence grows by up to two pubkey lists in mesh (about 2 KB at 15
  participants), sent every 30 s and on link changes.
- Native forwarding of remote tracks needs the vendored flutter_webrtc
  patch on Android (its `addTrack` and `replaceTrack` only looked up local
  tracks).
