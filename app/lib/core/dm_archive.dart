import 'dart:async';
import 'dart:convert';

import 'package:ndk/ndk.dart';

import 'groups/mls_bridge.dart';

/// The gift wraps of our DMs, kept as received: still encrypted to our key,
/// so the history outlives relays that drop old events. Keyed by the inner
/// message id, so disappearing messages can leave the archive too.
class DmArchive {
  DmArchive(this._store);

  final SnapshotStore _store;
  final Map<String, String> _wraps = {};
  Timer? _saveTimer;

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {'wraps': final Map<String, Object?> wraps}) {
      for (final MapEntry(:key, :value) in wraps.entries) {
        if (value is String) _wraps[key] = value;
      }
    }
  }

  /// Archived wraps, to replay through the same path as live ones.
  List<Nip01Event> get wraps => [
    for (final json in _wraps.values)
      if (jsonDecode(json) case final Map<String, Object?> map)
        Nip01EventModel.fromJson(map),
  ];

  void put(String messageId, Nip01Event wrap) {
    if (_wraps.containsKey(messageId)) return;
    _wraps[messageId] = Nip01EventModel.fromEntity(wrap).toJsonString();
    _saveSoon();
  }

  void removeAll(Iterable<String> messageIds) {
    final before = _wraps.length;
    messageIds.forEach(_wraps.remove);
    if (_wraps.length != before) _saveSoon();
  }

  /// Bursts of history arrive together; one write after them.
  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _store.write(jsonEncode({'wraps': _wraps}));
  }

  /// Writes what a pending save would have; nothing after [wipe].
  Future<void> close() async {
    if (_saveTimer?.isActive ?? false) await flush();
  }

  Future<void> wipe() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _wraps.clear();
    await _store.delete();
  }
}
