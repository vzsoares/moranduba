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
        when pubkey.isEmpty || _hexKey.hasMatch(pubkey) =>
      PreferredSfu(pubkey: pubkey, setAt: setAt),
    _ => null,
  };
}

/// A member's desktop SFU offered to a group. Per pubkey, the newest
/// [setAt] wins.
class HostPeer {
  const HostPeer({required this.on, required this.setAt});

  final bool on;

  /// Unix seconds.
  final int setAt;

  Map<String, Object> toJson() => {'on': on, 'set_at': setAt};

  static HostPeer? fromJson(Object? json) => switch (json) {
    {'on': final bool on, 'set_at': final int setAt} => HostPeer(
      on: on,
      setAt: setAt,
    ),
    _ => null,
  };
}

final _hexKey = RegExp(r'^[0-9a-f]{64}$');

/// Parses a `hosts` map, dropping malformed entries.
Map<String, HostPeer> hostPeersFromJson(Object? json) => {
  if (json is Map<String, Object?>)
    for (final MapEntry(:key, :value) in json.entries)
      if (_hexKey.hasMatch(key)) key: ?HostPeer.fromJson(value),
};

/// Each group's call server and host peers, the servers we own, and the
/// group epoch each choice was last announced on.
class SfuBook {
  SfuBook(this._store);

  final SnapshotStore _store;
  final Map<String, PreferredSfu> _preferred = {};
  final Map<String, Map<String, HostPeer>> _hosts = {};
  final Set<String> _owned = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    final json = jsonDecode(raw);
    if (json case {
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
    if (json case {'hosts': final Map<String, Object?> hosts}) {
      for (final MapEntry(:key, :value) in hosts.entries) {
        _hosts[key] = hostPeersFromJson(value);
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
      'hosts': {for (final groupId in _hosts.keys) groupId: hostsJson(groupId)},
    }),
  );

  PreferredSfu of(String groupId) => _preferred[groupId] ?? PreferredSfu.none;

  /// Opted-in host peers of [groupId], newest first.
  List<String> hostsOf(String groupId) {
    final hosts = [
      for (final MapEntry(:key, :value) in (_hosts[groupId] ?? {}).entries)
        if (value.on) (key, value.setAt),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (pubkey, _) in hosts) pubkey];
  }

  HostPeer? host(String groupId, String pubkey) => _hosts[groupId]?[pubkey];

  Map<String, Object> hostsJson(String groupId) => {
    for (final MapEntry(:key, :value) in (_hosts[groupId] ?? {}).entries)
      key: value.toJson(),
  };

  /// Groups whose call server or an opted-in host peer is [pubkey].
  Iterable<String> groupsOn(String pubkey) => {
    for (final e in _preferred.entries)
      if (e.value.pubkey == pubkey) e.key,
    for (final e in _hosts.entries)
      if (e.value[pubkey]?.on ?? false) e.key,
  };

  Set<String> get owned => Set.unmodifiable(_owned);

  /// Stores [sfu] for [groupId] if newer. Returns whether it changed.
  Future<bool> put(String groupId, PreferredSfu sfu) async {
    if (of(groupId).setAt >= sfu.setAt) return false;
    _preferred[groupId] = sfu;
    await _save();
    return true;
  }

  /// Merges [hosts] into [groupId]'s, newest entry per pubkey. Returns
  /// whether anything changed.
  Future<bool> putHosts(String groupId, Map<String, HostPeer> hosts) async {
    final known = _hosts.putIfAbsent(groupId, () => {});
    var changed = false;
    for (final MapEntry(:key, :value) in hosts.entries) {
      if ((known[key]?.setAt ?? -1) >= value.setAt) continue;
      known[key] = value;
      changed = true;
    }
    if (changed) await _save();
    return changed;
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
