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
