import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/calls/audio_prefs.dart';
import '../core/calls/volume.dart';
import '../core/session.dart';

/// Microphone, speaker and voice processing; changes apply to a call in
/// progress right away.
Future<void> showAudioSettings(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _AudioSettings(session: session),
    );

class _AudioSettings extends StatefulWidget {
  const _AudioSettings({required this.session});

  final Session session;

  @override
  State<_AudioSettings> createState() => _AudioSettingsState();
}

class _AudioSettingsState extends State<_AudioSettings> {
  late final Future<List<MediaDeviceInfo>> _devices = navigator.mediaDevices
      .enumerateDevices();
  late AudioPrefs _prefs = widget.session.audio.current;

  void _set(AudioPrefs prefs) {
    setState(() => _prefs = prefs);
    unawaited(widget.session.setAudio(prefs));
  }

  /// Browsers hide device names until the microphone was allowed once.
  static String _label(MediaDeviceInfo device, int index, String kind) =>
      device.label.isEmpty ? '$kind ${index + 1}' : device.label;

  Widget _picker({
    required String label,
    required String kind,
    required List<MediaDeviceInfo> devices,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    final known = devices.any((d) => d.deviceId == value);
    final picker = DropdownButtonFormField<String?>(
      initialValue: known ? value : null,
      isExpanded: true,
      items: [
        const DropdownMenuItem(value: null, child: Text('System default')),
        for (final (i, device) in devices.indexed)
          DropdownMenuItem(
            value: device.deviceId,
            child: Text(
              _label(device, i, kind),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        picker,
      ],
    );
  }

  /// 0 to 200%: past 100% the app amplifies.
  Widget _level(String label, double value, ValueChanged<double> onChanged) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$label · ${(value * 100).round()}%',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Slider(
            value: value,
            max: 2,
            divisions: 40,
            label: '${(value * 100).round()}%',
            onChanged: onChanged,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('AUDIO'),
    content: SizedBox(
      width: 440,
      child: FutureBuilder(
        future: _devices,
        builder: (context, snapshot) {
          final devices = snapshot.data ?? const <MediaDeviceInfo>[];
          final inputs = [
            for (final d in devices)
              if (d.kind == 'audioinput' && d.deviceId != 'default') d,
          ];
          final outputs = [
            for (final d in devices)
              if (d.kind == 'audiooutput' && d.deviceId != 'default') d,
          ];
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _picker(
                  label: 'Microphone',
                  kind: 'Microphone',
                  devices: inputs,
                  value: _prefs.input,
                  onChanged: (id) => _set(_prefs.copyWith(input: () => id)),
                ),
                // Some browsers cannot pick a speaker; then the system's plays.
                if (outputs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _picker(
                    label: 'Speaker',
                    kind: 'Speaker',
                    devices: outputs,
                    value: _prefs.output,
                    onChanged: (id) => _set(_prefs.copyWith(output: () => id)),
                  ),
                ],
                const SizedBox(height: 12),
                if (micLevelSupported)
                  _level(
                    'Microphone level',
                    _prefs.inputVolume,
                    (v) => _set(_prefs.copyWith(inputVolume: v)),
                  ),
                _level(
                  'Output volume',
                  _prefs.outputVolume,
                  (v) => _set(_prefs.copyWith(outputVolume: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Echo cancellation'),
                  value: _prefs.echoCancellation,
                  onChanged: (on) =>
                      _set(_prefs.copyWith(echoCancellation: on)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Noise suppression'),
                  value: _prefs.noiseSuppression,
                  onChanged: (on) =>
                      _set(_prefs.copyWith(noiseSuppression: on)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic gain'),
                  subtitle: const Text('Evens out how loud you sound'),
                  value: _prefs.autoGain,
                  onChanged: (on) => _set(_prefs.copyWith(autoGain: on)),
                ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  );
}
