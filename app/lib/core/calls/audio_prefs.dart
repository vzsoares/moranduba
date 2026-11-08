import 'dart:convert';

import '../groups/mls_bridge.dart';

/// Microphone, speaker and voice processing for calls, kept on this device.
/// Null devices mean the system default.
class AudioPrefs {
  const AudioPrefs({
    this.input,
    this.output,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGain = true,
    this.inputVolume = 1,
    this.outputVolume = 1,
  });

  final String? input;
  final String? output;
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGain;

  /// Microphone and overall playback levels, 0 to 2.
  final double inputVolume;
  final double outputVolume;

  /// getUserMedia audio constraints.
  Map<String, Object> constraints() => {
    'deviceId': ?input,
    'echoCancellation': echoCancellation,
    'noiseSuppression': noiseSuppression,
    'autoGainControl': autoGain,
  };

  AudioPrefs copyWith({
    String? Function()? input,
    String? Function()? output,
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? autoGain,
    double? inputVolume,
    double? outputVolume,
  }) => AudioPrefs(
    input: input == null ? this.input : input(),
    output: output == null ? this.output : output(),
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    autoGain: autoGain ?? this.autoGain,
    inputVolume: inputVolume ?? this.inputVolume,
    outputVolume: outputVolume ?? this.outputVolume,
  );

  Map<String, Object?> toJson() => {
    'input': input,
    'output': output,
    'echo_cancellation': echoCancellation,
    'noise_suppression': noiseSuppression,
    'auto_gain': autoGain,
    'input_volume': inputVolume,
    'output_volume': outputVolume,
  };

  static AudioPrefs fromJson(Object? json) => switch (json) {
    final Map<String, Object?> map => AudioPrefs(
      input: switch (map['input']) {
        final String id => id,
        _ => null,
      },
      output: switch (map['output']) {
        final String id => id,
        _ => null,
      },
      echoCancellation: map['echo_cancellation'] != false,
      noiseSuppression: map['noise_suppression'] != false,
      autoGain: map['auto_gain'] != false,
      inputVolume: _level(map['input_volume']),
      outputVolume: _level(map['output_volume']),
    ),
    _ => const AudioPrefs(),
  };
}

double _level(Object? json) => switch (json) {
  final num level => level.toDouble().clamp(0, 2),
  _ => 1,
};

class AudioPrefsBook {
  AudioPrefsBook(this._store);

  final SnapshotStore _store;
  AudioPrefs current = const AudioPrefs();

  Future<void> load() async {
    final raw = await _store.read();
    if (raw != null) current = AudioPrefs.fromJson(jsonDecode(raw));
  }

  Future<void> put(AudioPrefs prefs) async {
    current = prefs;
    await _store.write(jsonEncode(prefs.toJson()));
  }

  Future<void> wipe() => _store.delete();
}
