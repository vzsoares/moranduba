import 'dart:convert';

import 'groups/mls_bridge.dart';
import 'profiles.dart';

/// A group's picture. [picture] null means none; the newest [setAt] wins.
class GroupPicture {
  const GroupPicture({required this.picture, required this.setAt});

  static const initial = GroupPicture(picture: null, setAt: 0);

  final PictureRef? picture;

  /// Unix seconds.
  final int setAt;

  Map<String, Object?> toJson() => {
    'picture': picture?.toJson(),
    'set_at': setAt,
  };

  static GroupPicture? fromJson(Object? json) => switch (json) {
    {'set_at': final int setAt} => GroupPicture(
      picture: PictureRef.fromJson(json['picture']),
      setAt: setAt,
    ),
    _ => null,
  };
}

/// Each group's [GroupPicture] and the epoch it was last announced on.
class GroupPictureBook {
  GroupPictureBook(this._store);

  final SnapshotStore _store;
  final Map<String, GroupPicture> _pictures = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'pictures': final Map<String, Object?> pictures,
      'announced': final Map<String, Object?> announced,
    }) {
      for (final MapEntry(:key, :value) in pictures.entries) {
        if (GroupPicture.fromJson(value) case final p?) _pictures[key] = p;
      }
      for (final MapEntry(:key, :value) in announced.entries) {
        if (value is int) _announced[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'pictures': {for (final e in _pictures.entries) e.key: e.value.toJson()},
      'announced': _announced,
    }),
  );

  GroupPicture of(String groupId) => _pictures[groupId] ?? GroupPicture.initial;

  /// Stores [picture] if newer. Returns whether it changed.
  Future<bool> put(String groupId, GroupPicture picture) async {
    if (of(groupId).setAt >= picture.setAt) return false;
    _pictures[groupId] = picture;
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
