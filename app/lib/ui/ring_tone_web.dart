import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// A phone-style ring made with WebAudio: two tones for a second, then
/// two seconds of quiet. Browsers keep it silent until the page has had a
/// click or key press.
class RingTone {
  web.AudioContext? _context;
  Timer? _timer;

  void start() {
    if (_timer != null) return;
    final context = _context ??= web.AudioContext();
    unawaited(context.resume().toDart);
    _burst(context);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _burst(context));
  }

  void _burst(web.AudioContext context) {
    final now = context.currentTime;
    final gain = context.createGain();
    gain.connect(context.destination);
    gain.gain
      ..setValueAtTime(0, now)
      ..linearRampToValueAtTime(0.12, now + 0.05)
      ..setValueAtTime(0.12, now + 0.95)
      ..linearRampToValueAtTime(0, now + 1);
    for (final hertz in [440.0, 480.0]) {
      final tone = context.createOscillator();
      tone.frequency.value = hertz;
      tone.connect(gain);
      tone.start(now);
      tone.stop(now + 1);
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    unawaited(_context?.close().toDart);
    _context = null;
  }
}
