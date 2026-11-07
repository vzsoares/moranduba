import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// One context for every tone. Browsers keep audio off until the page gets
/// a click or key press, so the first one unlocks it ahead of any ring.
web.AudioContext? _shared;

web.AudioContext get _context => _shared ??= web.AudioContext();

/// Call before any ring: unlocks audio on the first click or key press.
void primeTones() {
  if (_shared != null) return;
  late final JSFunction unlock;
  unlock = ((web.Event _) {
    unawaited(_context.resume().toDart);
    web.document
      ..removeEventListener('pointerdown', unlock)
      ..removeEventListener('keydown', unlock);
  }).toJS;
  web.document
    ..addEventListener('pointerdown', unlock)
    ..addEventListener('keydown', unlock);
}

/// A repeating tone: [incoming] for the one being called, [ringback] for
/// the caller while nobody has answered.
class RingTone {
  RingTone.incoming()
    : _every = const Duration(seconds: 3),
      _bursts = const [(0, 0.4), (0.6, 1.0)],
      _hertz = const [440, 480],
      _volume = 0.15;

  RingTone.ringback()
    : _every = const Duration(seconds: 4),
      _bursts = const [(0, 1.0)],
      _hertz = const [425],
      _volume = 0.08;

  final Duration _every;

  /// Start and end of each burst, in seconds into the period.
  final List<(double, double)> _bursts;
  final List<double> _hertz;
  final double _volume;
  Timer? _timer;

  void start() {
    if (_timer != null) return;
    unawaited(_context.resume().toDart);
    _play();
    _timer = Timer.periodic(_every, (_) => _play());
  }

  void _play() {
    final context = _context;
    final now = context.currentTime;
    for (final (from, to) in _bursts) {
      final gain = context.createGain();
      gain.connect(context.destination);
      gain.gain
        ..setValueAtTime(0, now + from)
        ..linearRampToValueAtTime(_volume, now + from + 0.03)
        ..setValueAtTime(_volume, now + to - 0.03)
        ..linearRampToValueAtTime(0, now + to);
      for (final hertz in _hertz) {
        final tone = context.createOscillator();
        tone.frequency.value = hertz;
        tone.connect(gain);
        tone.start(now + from);
        tone.stop(now + to);
      }
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
