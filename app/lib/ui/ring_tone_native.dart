import 'dart:async';

import 'package:flutter/services.dart';

void primeTones() {}

/// [incoming] rings with the system alert sound and a buzz where there is a
/// motor. [ringback] stays silent: native has no tone to borrow for it.
class RingTone {
  RingTone.incoming() : _audible = true;

  RingTone.ringback() : _audible = false;

  final bool _audible;
  Timer? _timer;

  void start() {
    if (!_audible || _timer != null) return;
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
