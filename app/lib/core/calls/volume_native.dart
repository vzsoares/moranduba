import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _micGain = MethodChannel('moranduba/mic_gain');

/// macOS and Android scale the captured microphone in the app (MicGain),
/// Linux and Windows in the patched flutter_webrtc (`setCaptureGain`).
final micLevelSupported =
    Platform.isMacOS ||
    Platform.isAndroid ||
    Platform.isLinux ||
    Platform.isWindows;

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

/// The microphone at an adjustable level. The native gain is process-wide,
/// so only the newest level owns it.
class MicLevel {
  MicLevel._(this.stream);

  static MicLevel? _current;

  /// What gets sent: the raw capture, scaled natively.
  final MediaStream stream;

  set gain(double value) => unawaited(_setGain(value));

  /// Leaves the capture to its owner, which stops it.
  Future<void> dispose() async {
    if (!identical(_current, this)) return;
    _current = null;
    await _setGain(1);
  }
}

Future<bool> _setGain(double gain) async {
  try {
    final args = {'gain': gain};
    final set = Platform.isLinux || Platform.isWindows
        ? WebRTC.invokeMethod<bool, Map<String, double>>('setCaptureGain', args)
        : _micGain.invokeMethod<bool>('set', args);
    return await set ?? false;
  } on Exception catch (e) {
    debugPrint('mic gain: $e');
    return false;
  }
}

Future<MicLevel?> levelMic(MediaStream raw, double gain) async {
  if (!micLevelSupported || !await _setGain(gain)) return null;
  return MicLevel._current = MicLevel._(raw);
}
