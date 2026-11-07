import 'dart:convert';

import '../groups/group_engine.dart';
import '../groups/mls_bridge.dart';

/// A call starting or ending, as stored in the group's history.
class CallEvent {
  const CallEvent.started(this.callId) : ended = false, seconds = null;

  const CallEvent.ended(this.callId, {required int this.seconds})
    : ended = true;

  const CallEvent._(this.callId, {required this.ended, this.seconds});

  final String callId;
  final bool ended;

  /// How long the call ran; only on [ended].
  final int? seconds;

  String encode() => jsonEncode({
    'event': ended ? 'end' : 'start',
    'call': callId,
    'seconds': ?seconds,
  });

  static CallEvent? decode(String text) {
    try {
      return switch (jsonDecode(text)) {
        {'event': 'start', 'call': final String id} => CallEvent._(
          id,
          ended: false,
        ),
        {'event': 'end', 'call': final String id, 'seconds': final int s} =>
          CallEvent._(id, ended: true, seconds: s),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

/// One row per call: who started it and when, plus its length once over.
class CallLogEntry {
  const CallLogEntry({required this.start, this.seconds});

  final GroupMessage start;
  final int? seconds;
}

/// Chat messages with each call's start replaced by a [CallLogEntry] and
/// its end folded into it. Ends without a start (pruned) are dropped.
List<Object> withCallLog(List<GroupMessage> messages) {
  final lengths = <String, int>{};
  for (final m in messages) {
    if (!m.call) continue;
    if (CallEvent.decode(m.text) case CallEvent(
      ended: true,
      :final callId,
      :final seconds?,
    )) {
      lengths.putIfAbsent(callId, () => seconds);
    }
  }
  final seen = <String>{};
  return [
    for (final m in messages)
      if (!m.call)
        m
      else if (CallEvent.decode(m.text)
          case CallEvent(ended: false, :final callId) when seen.add(callId))
        CallLogEntry(start: m, seconds: lengths[callId]),
  ];
}

/// "1h 2m", "4m 10s", "35s".
String callLength(int seconds) {
  final h = seconds ~/ 3600;
  final m = seconds % 3600 ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// Whether a group logs its calls in the chat. Newest [setAt] wins; on by
/// default.
class CallLogSetting {
  const CallLogSetting({required this.on, required this.setAt});

  static const initial = CallLogSetting(on: true, setAt: 0);

  final bool on;

  /// Unix seconds.
  final int setAt;

  Map<String, Object> toJson() => {'on': on, 'set_at': setAt};

  static CallLogSetting? fromJson(Object? json) => switch (json) {
    {'on': final bool on, 'set_at': final int setAt} => CallLogSetting(
      on: on,
      setAt: setAt,
    ),
    _ => null,
  };
}

/// Each group's [CallLogSetting] and the epoch it was last announced on.
class CallLogBook {
  CallLogBook(this._store);

  final SnapshotStore _store;
  final Map<String, CallLogSetting> _settings = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'settings': final Map<String, Object?> settings,
      'announced': final Map<String, Object?> announced,
    }) {
      for (final MapEntry(:key, :value) in settings.entries) {
        if (CallLogSetting.fromJson(value) case final s?) _settings[key] = s;
      }
      for (final MapEntry(:key, :value) in announced.entries) {
        if (value is int) _announced[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'settings': {for (final e in _settings.entries) e.key: e.value.toJson()},
      'announced': _announced,
    }),
  );

  CallLogSetting of(String groupId) =>
      _settings[groupId] ?? CallLogSetting.initial;

  /// Stores [setting] if newer. Returns whether it changed.
  Future<bool> put(String groupId, CallLogSetting setting) async {
    if (of(groupId).setAt >= setting.setAt) return false;
    _settings[groupId] = setting;
    await _save();
    return true;
  }

  bool announcedOn(String groupId, int epoch) => _announced[groupId] == epoch;

  Future<void> markAnnounced(String groupId, int epoch) async {
    _announced[groupId] = epoch;
    await _save();
  }

  Future<void> wipe() => _store.delete();
}

/// One line for a message in previews and notifications.
String messagePreview(GroupMessage m) {
  if (m.call) {
    return switch (CallEvent.decode(m.text)) {
      CallEvent(ended: true, :final seconds?) =>
        'call ended · ${callLength(seconds)}',
      _ => 'started a call',
    };
  }
  if (m.text.isEmpty && m.media.isNotEmpty) {
    return 'sent ${m.media.first.filename}';
  }
  return m.text;
}
