import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

/// Sets how loud [renderer]'s audio plays here, 0 to 1. flutter_webrtc
/// plays it through an <audio> element named after the renderer.
Future<void> setPlaybackVolume(
  RTCVideoRenderer? renderer,
  MediaStream? stream,
  double volume,
) async {
  final id = renderer?.textureId;
  if (id == null) return;
  web.document
      .getElementById('audio_RTCVideoRenderer-$id')
      ?.setProperty('volume'.toJS, volume.clamp(0, 1).toJS);
}
