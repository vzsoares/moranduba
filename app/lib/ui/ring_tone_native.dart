import 'dart:async';

import 'package:flutter/services.dart';

/// Rings with the system alert sound, and a buzz where there is a motor.
class RingTone {
  Timer? _timer;

  void start() {
    if (_timer != null) return;
    _ring();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _ring());
  }

  void _ring() {
    unawaited(SystemSound.play(SystemSoundType.alert));
    unawaited(HapticFeedback.vibrate());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
