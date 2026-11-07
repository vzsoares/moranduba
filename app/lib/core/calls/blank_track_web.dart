import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

/// A video track that sends nothing, from an unpainted canvas.
Future<MediaStreamTrack?> blankVideoTrack() async {
  final canvas = web.HTMLCanvasElement()
    ..width = 2
    ..height = 2;
  final track = canvas.captureStream(0).getVideoTracks().toDart.firstOrNull;
  return track == null ? null : MediaStreamTrackWeb(track);
}
