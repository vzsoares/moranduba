import 'dart:math';
import 'dart:typed_data';

/// Moments the app plays a sound for; each gets a [Tone] the user picks.
enum Sound {
  ring('Incoming call', Tone.phone, every: Duration(seconds: 3)),
  ringback('Calling out', Tone.beep, every: Duration(seconds: 4)),
  invite('Friend request or group invite', Tone.chime),
  message('New message', Tone.off);

  const Sound(this.label, this.byDefault, {this.every});

  final String label;
  final Tone byDefault;

  /// How often a ringing sound repeats; null plays once.
  final Duration? every;
}

/// One burst: [from] and [to] in seconds, sine waves at [hertz].
/// [fade] decays from the start instead of holding, like a struck bell.
class Note {
  const Note(this.from, this.to, this.hertz, {this.fade = false});

  final double from;
  final double to;
  final List<double> hertz;
  final bool fade;
}

enum Tone {
  phone('Phone', 0.15, [
    Note(0, 0.4, [440, 480]),
    Note(0.6, 1.0, [440, 480]),
  ]),
  beep('Beep', 0.08, [
    Note(0, 1.0, [425]),
  ]),
  chime('Chime', 0.12, [
    Note(0, 0.35, [660], fade: true),
    Note(0.12, 0.5, [880], fade: true),
    Note(0.24, 0.9, [1320], fade: true),
  ]),
  bell('Bell', 0.12, [
    Note(0, 1.2, [880, 1760], fade: true),
  ]),
  pop('Pop', 0.15, [
    Note(0, 0.07, [1200]),
    Note(0.1, 0.17, [1600]),
  ]),
  off('Off', 0, []);

  const Tone(this.label, this.volume, this.notes);

  final String label;
  final double volume;
  final List<Note> notes;

  static Tone? named(Object? name) =>
      Tone.values.where((t) => t.name == name).firstOrNull;

  Duration get length => Duration(
    milliseconds: (notes.fold(0.0, (end, n) => max(end, n.to)) * 1000).round(),
  );

  /// Gain at [t] seconds into [note]: short ramps avoid clicks.
  double gainAt(Note note, double t) {
    const ramp = 0.03;
    final into = t - note.from;
    final left = note.to - t;
    if (into < 0 || left < 0) return 0;
    if (note.fade) {
      return volume * min(1, into / 0.005) * (left / (note.to - note.from));
    }
    return volume * min(1, min(into, left) / ramp);
  }
}

/// [tone] as 16-bit mono PCM in a WAV file, for players that need a file.
Uint8List renderWav(Tone tone, {int rate = 22050}) {
  final samples = (tone.length.inMicroseconds * rate / 1e6).ceil();
  final data = ByteData(44 + samples * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final t = i / rate;
    var value = 0.0;
    for (final note in tone.notes) {
      final gain = tone.gainAt(note, t);
      if (gain == 0) continue;
      for (final hertz in note.hertz) {
        value += gain * sin(2 * pi * hertz * t);
      }
    }
    data.setInt16(
      44 + i * 2,
      (value.clamp(-1.0, 1.0) * 32767).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}
