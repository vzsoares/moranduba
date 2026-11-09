import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/audio_prefs.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/sounds.dart';

void main() {
  test('constraints name the device only when one is picked', () {
    expect(const AudioPrefs().constraints().containsKey('deviceId'), isFalse);
    final picked = const AudioPrefs(
      input: 'mic-2',
      noiseSuppression: false,
    ).constraints();
    expect(picked['deviceId'], 'mic-2');
    expect(picked['noiseSuppression'], false);
    expect(picked['echoCancellation'], true);
  });

  test('prefs survive a reload and clear back to the default', () async {
    final store = MemorySnapshotStore();
    final book = AudioPrefsBook(store);
    await book.put(
      const AudioPrefs(input: 'mic-2', output: 'spk-1', autoGain: false),
    );
    final reloaded = AudioPrefsBook(store);
    await reloaded.load();
    expect(reloaded.current.input, 'mic-2');
    expect(reloaded.current.output, 'spk-1');
    expect(reloaded.current.autoGain, isFalse);
    expect(reloaded.current.copyWith(input: () => null).input, isNull);
  });

  test('picked tones survive a reload; the rest keep their default', () async {
    final store = MemorySnapshotStore();
    await AudioPrefsBook(store).put(
      const AudioPrefs(sounds: {Sound.invite: Tone.pop, Sound.ring: Tone.off}),
    );
    final reloaded = AudioPrefsBook(store);
    await reloaded.load();
    expect(reloaded.current.toneFor(Sound.invite), Tone.pop);
    expect(reloaded.current.toneFor(Sound.ring), Tone.off);
    expect(reloaded.current.toneFor(Sound.ringback), Sound.ringback.byDefault);
    expect(
      AudioPrefs.fromJson({
        'sounds': {'invite': 'gone'},
      }).toneFor(Sound.invite),
      Sound.invite.byDefault,
    );
  });
}
