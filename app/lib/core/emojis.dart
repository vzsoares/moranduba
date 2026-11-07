import 'dart:convert';

import 'groups/mls_bridge.dart';
import 'profiles.dart';

/// `:name:` in a message; names are lowercase letters, digits and `_`.
final emojiPattern = RegExp(r':([a-z0-9_]{2,32}):');

/// Turns a picked file name into an emoji name, or null when nothing usable
/// is left.
String? emojiName(String raw) {
  final name = raw
      .toLowerCase()
      .replaceAll(RegExp(r'\.[a-z0-9]+$'), '')
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (name.length < 2) return null;
  return name.length > 32 ? name.substring(0, 32) : name;
}

/// A group's custom emoji. [picture] null means it was removed; the newest
/// [setAt] per name wins.
class CustomEmoji {
  const CustomEmoji({
    required this.name,
    required this.picture,
    required this.setAt,
  });

  final String name;
  final PictureRef? picture;

  /// Unix seconds.
  final int setAt;

  Map<String, Object?> toJson() => {
    'name': name,
    'picture': picture?.toJson(),
    'set_at': setAt,
  };

  static CustomEmoji? fromJson(Object? json) => switch (json) {
    {'name': final String name, 'set_at': final int setAt}
        when emojiPattern.hasMatch(':$name:') =>
      CustomEmoji(
        name: name,
        picture: PictureRef.fromJson(json['picture']),
        setAt: setAt,
      ),
    _ => null,
  };
}

/// Each group's custom emojis and the epoch they were last announced on.
class EmojiBook {
  EmojiBook(this._store);

  final SnapshotStore _store;
  final Map<String, Map<String, CustomEmoji>> _emojis = {};
  final Map<String, int> _announced = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'emojis': final Map<String, Object?> emojis,
      'announced': final Map<String, Object?> announced,
    }) {
      for (final MapEntry(key: groupId, value: list) in emojis.entries) {
        if (list is! List<Object?>) continue;
        for (final json in list) {
          if (CustomEmoji.fromJson(json) case final emoji?) {
            _emojis.putIfAbsent(groupId, () => {})[emoji.name] = emoji;
          }
        }
      }
      for (final MapEntry(:key, :value) in announced.entries) {
        if (value is int) _announced[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'emojis': {
        for (final e in _emojis.entries)
          e.key: [for (final emoji in e.value.values) emoji.toJson()],
      },
      'announced': _announced,
    }),
  );

  /// Every entry for [groupId], removals included, for announcing.
  List<CustomEmoji> entries(String groupId) => [...?_emojis[groupId]?.values];

  /// The usable emojis of [groupId], by name.
  Map<String, PictureRef> of(String groupId) => {
    for (final emoji in entries(groupId)) emoji.name: ?emoji.picture,
  };

  /// Stores [emoji] if newer than what [groupId] has under its name.
  /// Returns whether it changed.
  Future<bool> put(String groupId, CustomEmoji emoji) async {
    final emojis = _emojis.putIfAbsent(groupId, () => {});
    if ((emojis[emoji.name]?.setAt ?? -1) >= emoji.setAt) return false;
    emojis[emoji.name] = emoji;
    await _save();
    return true;
  }

  /// When [groupId]'s entry for [name] was last set, or null.
  int? setAt(String groupId, String name) => _emojis[groupId]?[name]?.setAt;

  bool announcedOn(String groupId, int epoch) => _announced[groupId] == epoch;

  Future<void> markAnnounced(String groupId, int epoch) async {
    _announced[groupId] = epoch;
    await _save();
  }

  Future<void> wipe() => _store.delete();
}
