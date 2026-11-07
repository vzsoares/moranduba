import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// `android/.../CallService.kt`: keeps a call alive in the background and
/// holds the foreground service Android 14 needs before screen capture.
const _service = MethodChannel('moranduba/call_service');

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

class ScreenCaptureDenied implements Exception {
  const ScreenCaptureDenied();

  @override
  String toString() => 'Screen sharing was not allowed';
}

Future<void> _call(String method, [Map<String, Object>? arguments]) async {
  if (!_android) return;
  try {
    await _service.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // Host tests run with the Android target platform but no engine.
  }
}

/// Tells Android a call is running, so it keeps the mic and camera.
Future<void> callServiceUpdate({required bool sharing}) =>
    _call('update', {'sharing': sharing});

Future<void> callServiceStop() => _call('stop');

/// Asks the OS for the whole screen. iOS shows the broadcast picker for the
/// `Broadcast` extension; Android asks for consent first.
Future<MediaStream> captureScreen() async {
  if (_android) {
    if (!await Helper.requestCapturePermission()) {
      throw const ScreenCaptureDenied();
    }
    await callServiceUpdate(sharing: true);
  }
  try {
    return await navigator.mediaDevices.getDisplayMedia({
      'video': _ios ? {'deviceId': 'broadcast'} : true,
      'audio': false,
    });
  } catch (_) {
    if (_android) await callServiceUpdate(sharing: false);
    rethrow;
  }
}
