import 'dart:convert';

import 'groups/mls_bridge.dart';

/// Disappearing-message timer for one chat. The newest [setAt] wins.
class ChatExpiry {
  const ChatExpiry({required this.seconds, required this.setAt});

  static const off = ChatExpiry(seconds: 0, setAt: 0);

  /// 0 keeps messages.
  final int seconds;

  /// Unix seconds.
  final int setAt;

  bool get isOn => seconds > 0;

  Map<String, int> toJson() => {'seconds': seconds, 'set_at': setAt};

  static ChatExpiry? fromJson(Object? json) => switch (json) {
    {'seconds': final int seconds, 'set_at': final int setAt}
        when seconds >= 0 =>
      ChatExpiry(seconds: seconds, setAt: setAt),
    _ => null,
  };

  static ChatExpiry? decode(String payload) {
    try {
      return fromJson(jsonDecode(payload));
    } on FormatException {
      return null;
    }
  }
}

/// Timer choices offered in the UI, in seconds.
const expiryChoices = [0, 3600, 86400, 604800];

String expiryLabel(int seconds) => switch (seconds) {
  0 => 'Off',
  604800 => '1 week',
  86400 => '24 hours',
  3600 => '1 hour',
  < 3600 => '${seconds ~/ 60} min',
  < 86400 => '${seconds ~/ 3600} h',
  _ => '${seconds ~/ 86400} days',
};

/// Chat ids for [ExpiryBook].
String dmChat(String pubkey) => 'dm:$pubkey';
String groupChat(String groupId) => 'group:$groupId';

/// Per-chat timers, plus the group epoch each timer was last announced on.
class ExpiryBook {
  ExpiryBook(this._store);

  final SnapshotStore _store;
  final Map<String, ChatExpiry> _timers = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'timers': final Map<String, Object?> timers,
      'announced': final Map<String, Object?> announced,
    }) {
      for (final MapEntry(:key, :value) in timers.entries) {
        if (ChatExpiry.fromJson(value) case final timer?) _timers[key] = timer;
      }
      for (final MapEntry(:key, :value) in announced.entries) {
        if (value is int) _announced[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'timers': {for (final e in _timers.entries) e.key: e.value.toJson()},
      'announced': _announced,
    }),
  );

  ChatExpiry of(String chat) => _timers[chat] ?? ChatExpiry.off;

  Iterable<MapEntry<String, ChatExpiry>> get active =>
      _timers.entries.where((e) => e.value.isOn);

  /// Stores [timer] if newer. Returns whether it changed.
  Future<bool> put(String chat, ChatExpiry timer) async {
    if (of(chat).setAt >= timer.setAt) return false;
    _timers[chat] = timer;
    await _save();
    return true;
  }

  bool announcedOn(String chat, int epoch) => _announced[chat] == epoch;

  Future<void> markAnnounced(String chat, int epoch) async {
    _announced[chat] = epoch;
    await _save();
  }

  Future<void> wipe() => _store.delete();
}
