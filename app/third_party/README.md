# Vendored packages

## flutter_webrtc 1.6.3

Pub release without `example/`, plus `flutter_webrtc.patch`: a
`setCaptureGain` method on Linux and Windows that scales the captured
microphone (the input volume slider). macOS and Android get the same gain
from the app's own `MicGain`, so they need no patch.

The patch also lets Android's `addTrack` and `replaceTrack` take a remote
track, so a call member can relay one peer's media to another (ADR 0003);
the other platforms already look up remote tracks.

To upgrade: copy the new release here, then
`patch -p1 -d flutter_webrtc < flutter_webrtc.patch`, and keep the
`compileOnly` webrtc-sdk version in `android/app/build.gradle.kts` in step.

## dart_webrtc 1.8.2

flutter_webrtc's web implementation, wired in with `dependency_overrides`.
Pub release without `web/` (its demo), plus `dart_webrtc.patch`, which
fixes the frame-encryption worker (`e2ee.worker.dart.js`):

- Each `FrameCryptor` gets its own `cryptorId`, sent with every message and
  state event. The worker keyed cryptors by track id, so links sending the
  same local track shared one, and closing a link stopped state events for
  the others.
- `dispose` removes the cryptor from the worker; it only marked it before,
  so cryptors piled up across redials and relays.
- A `cryptorCount` message reports the cryptors alive, for the e2e tests.

`web/e2ee_receivers.js` sends the same messages for the receivers it
attaches. The worker is built from this tree by `tool/build_web_assets.sh`.

To upgrade: copy the new release here without `web/`, then
`patch -p1 -d dart_webrtc < dart_webrtc.patch`.
