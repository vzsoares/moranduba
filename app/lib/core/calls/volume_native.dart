import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// flutter_webrtc has no gain stage for the microphone on native.
const micLevelSupported = false;

/// Sets how loud [stream] plays here, 0 to 2; libwebrtc's track volume
/// goes past 1.
Future<void> setPlaybackVolume(
  RTCVideoRenderer? renderer,
  MediaStream? stream,
  double volume,
) async {
  for (final track in stream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
    try {
      await Helper.setVolume(volume, track);
    } catch (e) {
      debugPrint('volume: $e');
    }
  }
}

void releasePlayback(RTCVideoRenderer? renderer) {}

/// Never built here: [levelMic] returns null on native.
abstract interface class MicLevel {
  MediaStream get stream;

  set gain(double value);

  Future<void> dispose();
}

Future<MicLevel?> levelMic(MediaStream raw, double gain) async => null;
