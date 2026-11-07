import 'dart:convert';

import '../groups/mls_bridge.dart';

/// A group's call server. Empty [pubkey] means none; the newest [setAt] wins.
class PreferredSfu {
  const PreferredSfu({required this.pubkey, required this.setAt});

  static const none = PreferredSfu(pubkey: '', setAt: 0);

  /// Hex.
  final String pubkey;

  /// Unix seconds.
  final int setAt;

  Map<String, Object> toJson() => {'pubkey': pubkey, 'set_at': setAt};

  static PreferredSfu? fromJson(Object? json) => switch (json) {
    {'pubkey': final String pubkey, 'set_at': final int setAt}
        when pubkey.isEmpty || RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey) =>
      PreferredSfu(pubkey: pubkey, setAt: setAt),
    _ => null,
  };
}

/// Each group's call server, the servers we own, and the group epoch each
/// choice was last announced on.
class SfuBook {
  SfuBook(this._store);

  final SnapshotStore _store;
  final Map<String, PreferredSfu> _preferred = {};
  final Set<String> _owned = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'preferred': final Map<String, Object?> preferred,
      'owned': final List<Object?> owned,
      'announced': final Map<String, Object?> announced,
    }) {
      for (final MapEntry(:key, :value) in preferred.entries) {
        if (PreferredSfu.fromJson(value) case final sfu?) _preferred[key] = sfu;
      }
      _owned.addAll(owned.whereType<String>());
      for (final MapEntry(:key, :value) in announced.entries) {
        if (value is int) _announced[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'preferred': {
        for (final e in _preferred.entries) e.key: e.value.toJson(),
      },
      'owned': [..._owned],
      'announced': _announced,
    }),
  );

  PreferredSfu of(String groupId) => _preferred[groupId] ?? PreferredSfu.none;

  /// Groups whose call server is [pubkey].
  Iterable<String> groupsOn(String pubkey) => [
    for (final e in _preferred.entries)
      if (e.value.pubkey == pubkey) e.key,
  ];

  Set<String> get owned => Set.unmodifiable(_owned);

  /// Stores [sfu] for [groupId] if newer. Returns whether it changed.
  Future<bool> put(String groupId, PreferredSfu sfu) async {
    if (of(groupId).setAt >= sfu.setAt) return false;
    _preferred[groupId] = sfu;
    await _save();
    return true;
  }

  Future<void> own(String pubkey) async {
    if (_owned.add(pubkey)) await _save();
  }

  bool announcedOn(String groupId, int epoch) => _announced[groupId] == epoch;

  Future<void> markAnnounced(String groupId, int epoch) async {
    _announced[groupId] = epoch;
    await _save();
  }

  Future<void> wipe() => _store.delete();
}
