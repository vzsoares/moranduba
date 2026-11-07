# Moranduba

*Moranduba* (Old Tupi): news, stories that are told.

Private group chat with E2EE video calls and screen share, built on Nostr.
No accounts. Calls run peer to peer, through a member's desktop, or through a
self-hosted SFU, and can switch between them mid-call.

Status: phase 0 (identity, friends, 1:1 chat) works. Plan: [docs/architecture.md](docs/architecture.md).

## Develop

```sh
docker compose -f dev/docker-compose.yml up -d   # local relay on :7777
cd app
flutter run -d chrome \
  --dart-define=MORANDUBA_RELAYS=ws://localhost:7777
```

Checks:

```sh
cd app
flutter analyze
flutter test                          # unit tests
flutter test --run-skipped -t relay   # end to end, needs the dev relay
```

Native builds need the Rust toolchain (`mise install rust`), because `ndk`
compiles a Rust library through Dart build hooks.

UI follows the "Manga Instructional Comic" DESIGN.md. Fonts are Bangers,
Comic Neue and JetBrains Mono (all OFL, bundled in `app/assets/fonts`).
