import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/sounds.dart';

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

/// Plays [tone] once through WebAudio.
Future<void> playTone(Tone tone) async {
  final context = _context;
  // Suspended until the page had a click; the notes wait with it.
  unawaited(context.resume().toDart);
  final now = context.currentTime;
  for (final note in tone.notes) {
    final from = now + note.from;
    final to = now + note.to;
    final gain = context.createGain();
    gain.connect(context.destination);
    gain.gain.setValueAtTime(0, from);
    if (note.fade) {
      gain.gain
        ..linearRampToValueAtTime(tone.volume, from + 0.005)
        ..linearRampToValueAtTime(0, to);
    } else {
      gain.gain
        ..linearRampToValueAtTime(tone.volume, from + 0.03)
        ..setValueAtTime(tone.volume, to - 0.03)
        ..linearRampToValueAtTime(0, to);
    }
    for (final hertz in note.hertz) {
      final oscillator = context.createOscillator();
      oscillator.frequency.value = hertz;
      oscillator.connect(gain);
      oscillator.start(from);
      oscillator.stop(to);
    }
  }
}
