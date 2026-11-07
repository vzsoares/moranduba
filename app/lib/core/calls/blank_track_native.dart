import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Native libwebrtc attaches sender cryptors without a track.
Future<MediaStreamTrack?> blankVideoTrack() async => null;
