# Moranduba

*Moranduba* (Old Tupi): news, stories that are told.

Private group chat with E2EE video calls and screen share, built on Nostr.
No accounts. Calls run peer to peer, through a member's desktop, or through a
self-hosted SFU, and can switch between them mid-call.

Status: identity, friends, 1:1 chat, encrypted groups (MLS), attachments,
profiles, disappearing messages, and encrypted calls (mesh, or through a
Moranduba SFU in `sfu/`) work on the web; desktop builds share the same code.
Plan: [docs/architecture.md](docs/architecture.md).

## Develop

Every platform needs Rust (`mise install rust`): the MLS engine in
`app/rust/` and `ndk` both compile through Dart build hooks. The pinned
toolchain (1.98.1) installs itself on first build.

```sh
docker compose -f dev/docker-compose.yml up -d   # relay :7777, Blossom :8800
cd app
./tool/build_web_assets.sh                          # wasm engine, web only
flutter run -d chrome \
  --dart-define=MORANDUBA_RELAYS=ws://localhost:7777 \
  --dart-define=MORANDUBA_BLOSSOM=http://localhost:8800
```

The compose file also runs a throwaway Blossom server on :8800 (memory only).

Desktop runs the same way with `-d macos`, `-d windows` or `-d linux`; the
build hook compiles the engine for that platform. Per platform:

| Platform | Needs |
|---|---|
| Web | `rustup component add llvm-tools --toolchain 1.98.1`, `cargo install wasm-bindgen-cli --version 0.2.130 --locked` |
| macOS | Xcode |
| Windows | Visual Studio with "Desktop development with C++" |
| Linux | clang, cmake, ninja, pkg-config, GTK 3 and libsecret dev packages (Arch: `pacman -S clang cmake ninja gtk3 libsecret`) |

Two browser identities: serve the web build on two ports (each origin keeps
its own key).

Other devices (phone, second machine): `./dev/tunnel.sh` puts the app, relay
and Blossom on public HTTPS URLs through Cloudflare quick tunnels (no account;
`brew install cloudflared`) and prints the app URL. URLs change every run.

Checks:

```sh
cd app
flutter analyze
flutter test                          # unit tests, engine through FFI
flutter test --run-skipped -t relay   # end to end, needs the dev relay
(cd rust && cargo test)               # engine
./tool/test_web_mls.sh                # engine as wasm, under Node
./e2e/run.sh                          # encrypted call, two headless Chromes
```

## Deploy

```sh
MORANDUBA_RELAYS=wss://relay.example.com ./site/build.sh
```

Pictures go to Blossom servers that accept encrypted blobs (`nostr.download`,
`blossom.yakihonne.com`, `files.sovbit.host`) unless `MORANDUBA_BLOSSOM` is
set, as a `--dart-define` or in the environment of `site/build.sh`.

`build/site/` is static: the landing page at `/`, the web app at `/app/`.
Serve it from any static host; `.wasm` must go out as `application/wasm`.

UI follows the "Manga Instructional Comic" DESIGN.md. Fonts are Bangers,
Comic Neue and JetBrains Mono (all OFL, bundled in `app/assets/fonts`).
