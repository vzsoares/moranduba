import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Sets how loud [stream] plays here, 0 to 1.
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
