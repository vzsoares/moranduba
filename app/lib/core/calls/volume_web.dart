import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

/// The microphone level can be set here.
const micLevelSupported = true;

web.AudioContext? _shared;

web.AudioContext get _context => _shared ??= web.AudioContext();

/// A remote stream played through WebAudio, for volumes above 1.
class _Boost {
  _Boost(this.streamId, this.source, this.gain);

  final String streamId;
  final web.MediaStreamAudioSourceNode source;
  final web.GainNode gain;

  void dispose() {
    source.disconnect();
    gain.disconnect();
  }
}

final Map<int, _Boost> _boosts = {};

/// Plays [renderer]'s audio at [volume], 0 to 2. flutter_webrtc plays it
/// through an <audio> element named after the renderer, and elements stop
/// at 1; above that the element is muted and a WebAudio gain plays it.
Future<void> setPlaybackVolume(
  RTCVideoRenderer? renderer,
  MediaStream? stream,
  double volume,
) async {
  final id = renderer?.textureId;
  if (id == null) return;
  final element = web.document.getElementById('audio_RTCVideoRenderer-$id');
  if (volume <= 1 || stream is! MediaStreamWeb) {
    _boosts.remove(id)?.dispose();
    element?.setProperty('muted'.toJS, false.toJS);
    element?.setProperty('volume'.toJS, volume.clamp(0, 1).toJS);
    return;
  }
  // The element keeps playing, muted: Chrome feeds WebAudio nothing from a
  // remote stream that no element plays.
  element?.setProperty('muted'.toJS, true.toJS);
  var boost = _boosts[id];
  if (boost == null || boost.streamId != stream.id) {
    boost?.dispose();
    final source = _context.createMediaStreamSource(stream.jsStream);
    final gain = _context.createGain();
    source.connect(gain);
    gain.connect(_context.destination);
    boost = _boosts[id] = _Boost(stream.id, source, gain);
  }
  boost.gain.gain.value = volume;
  unawaited(_context.resume().toDart);
}

/// Stops boosting [renderer], when its participant leaves.
void releasePlayback(RTCVideoRenderer? renderer) {
  final id = renderer?.textureId;
  if (id != null) _boosts.remove(id)?.dispose();
}

/// The microphone sent at an adjustable level: raw capture through a
/// WebAudio gain into a new track.
class MicLevel {
  MicLevel._(this.stream, this._raw, this._source, this._gain);

  /// What gets sent.
  final MediaStream stream;
  final MediaStream _raw;
  final web.MediaStreamAudioSourceNode _source;
  final web.GainNode _gain;

  set gain(double value) => _gain.gain.value = value;

  Future<void> dispose() async {
    _source.disconnect();
    _gain.disconnect();
    for (final track in _raw.getTracks()) {
      await track.stop();
    }
  }
}

Future<MicLevel?> levelMic(MediaStream raw, double gain) async {
  if (raw is! MediaStreamWeb) return null;
  final source = _context.createMediaStreamSource(raw.jsStream);
  final node = _context.createGain()..gain.value = gain;
  final destination = _context.createMediaStreamDestination();
  source.connect(node);
  node.connect(destination);
  unawaited(_context.resume().toDart);
  return MicLevel._(
    MediaStreamWeb(destination.stream, 'local'),
    raw,
    source,
    node,
  );
}
