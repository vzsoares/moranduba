import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/sounds.dart';

void main() {
  test('a tone renders as mono 16-bit WAV of its length', () {
    final wav = renderWav(Tone.phone, rate: 8000);
    final data = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 8000);
    expect(data.getUint32(40, Endian.little), 8000 * 2);
    expect(wav.length, 44 + 8000 * 2);
  });

  test('the gap between bursts is silent and bursts are not', () {
    final data = ByteData.sublistView(renderWav(Tone.phone, rate: 8000));
    int peak(double from, double to) {
      var peak = 0;
      for (var i = (from * 8000).round(); i < (to * 8000).round(); i++) {
        final v = data.getInt16(44 + i * 2, Endian.little).abs();
        if (v > peak) peak = v;
      }
      return peak;
    }

    expect(peak(0.45, 0.55), 0);
    expect(peak(0.1, 0.3), greaterThan(32767 * 0.2));
  });

  test('every playable tone has notes and stays in range', () {
    for (final tone in Tone.values.where((t) => t != Tone.off)) {
      expect(tone.notes, isNotEmpty, reason: tone.name);
      final data = ByteData.sublistView(renderWav(tone, rate: 8000));
      for (var at = 44; at < data.lengthInBytes; at += 2) {
        expect(data.getInt16(at, Endian.little).abs(), lessThan(32767));
      }
    }
    expect(Tone.off.length, Duration.zero);
  });
}
