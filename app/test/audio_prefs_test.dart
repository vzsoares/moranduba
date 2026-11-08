import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/audio_prefs.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';

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
}
