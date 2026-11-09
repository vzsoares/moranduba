import 'dart:async';

import 'package:flutter/services.dart';

import '../core/session.dart';
import '../core/sounds.dart';
import 'tone_player.dart';

export 'tone_player.dart' show primeTones;

/// Plays the tone picked for [sound] once.
void playSound(Session session, Sound sound) {
  final tone = session.audio.current.toneFor(sound);
  if (tone != Tone.off) unawaited(playTone(tone));
}

/// Repeats [sound]'s picked tone until stopped: [Sound.ring] for the one
/// being called, [Sound.ringback] for the caller while nobody answered.
class RingTone {
  RingTone(this.sound, this._tone);

  final Sound sound;
  final Tone Function() _tone;
  Timer? _timer;

  void start() {
    if (_timer != null) return;
    _play();
    _timer = Timer.periodic(sound.every!, (_) => _play());
  }

  void _play() {
    final tone = _tone();
    if (tone != Tone.off) unawaited(playTone(tone));
    if (sound == Sound.ring) unawaited(HapticFeedback.vibrate());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
