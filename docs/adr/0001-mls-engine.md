# ADR 0001: One MLS engine on every platform

Date: 2026-11-07. Status: accepted.

## Context

Groups must work on Windows, Linux, macOS and the web, and all four must share
the same groups. The plan named MDK through `marmot_dart` or our own
flutter_rust_bridge wrapper.

What we found:

- `marmot_dart` 0.0.8 pins MDK 0.8, is FFI only (no web), and has no users.
- MDK itself moved to 0.14 with a new engine (`cgka-engine`) and a large
  app runtime (`marmot-app`, C ABI). Its wasm support is a compile check only,
  with no browser storage or runtime.
- marmot-ts runs in browsers but tracks Marmot v2. MDK 0.8 speaks the older
  wire format, so a marmot-ts web client could not share groups with an MDK
  0.8 desktop client.
- `mdk-core` 0.8 with the in-memory store compiles to `wasm32-unknown-unknown`.

## Decision

`app/rust/` is our own crate over `mdk-core` 0.8 and `mdk-memory-storage`,
built for desktop through a Dart build hook (`hook/build.dart`, the same
`native_toolchain_rust` path `ndk` uses) and for the browser with
wasm-bindgen (`tool/build_web_assets.sh`).

- One entry point, `call(handle, method, json) -> json`: `@Native` FFI on
  desktop, `mlsCall` in wasm. No codegen.
- State lives in memory. After every change the engine returns a snapshot,
  encrypted with ChaCha20-Poly1305 under a per-identity key from the secure
  store. Desktop writes it to the app support directory, the web to
  IndexedDB.
- Relays stay in Dart (`ndk`): the engine takes and returns raw events.
- Attachments (MIP-04): the engine encrypts and decrypts; Dart uploads the
  ciphertext to Blossom, authorizing each upload with a throwaway key so the
  server can't tie uploads to an identity. Pictures only for now.

Vendored patches (each crate has a `MORANDUBA.md`):

- `mdk-memory-storage`: serde form of the full snapshot.
- `mdk-core` and `mdk-memory-storage`: `web_time` instead of `std::time`,
  whose clock panics on wasm.
- `mdk-core`: `pending_removed_members_pubkeys` reports SelfRemove senders.

## Consequences

- Same code and wire format everywhere, testable in `cargo test`,
  `flutter test` (FFI) and Node (wasm, `tool/test_web_mls.sh`).
- No interop with current White Noise (MDK 0.14 / Marmot v2). Moving to the
  new engine is a later migration, once it ships browser storage.
- Every member auto-commits a leave, and MDK 0.8 cannot roll back a commit it
  merged itself. Only the lowest remaining pubkey publishes the leave commit;
  the others drop theirs. If that member is offline, the leaver stays in the
  member list until they return.
- Two admins adding members in the same epoch can still split the group.
  Rare in friend groups; the new MDK engine fixes it.
- Every initial member is an admin, because MIP-03 lets only non-admins leave
  and the last admin cannot step down. Members added later are not admins.
- Snapshots are rewritten whole after each change, capped by MDK's 10,000
  messages per group. Fine for friend groups; revisit for large ones.
- The browser download grows by about 5.9 MB of wasm (about 2.3 MB gzipped),
  most of it image handling for MIP-04.
