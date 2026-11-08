import 'dart:convert';

import 'groups/mls_bridge.dart';
import 'profiles.dart';

/// One saved GIF; [sha256] of the plaintext keeps a GIF from being saved
/// twice, since each upload gets a fresh key.
class SavedGif {
  const SavedGif({required this.picture, required this.sha256});

  final PictureRef picture;
  final String sha256;

  Map<String, Object> toJson() => {
    'picture': picture.toJson(),
    'sha256': sha256,
  };

  static SavedGif? fromJson(Object? json) => switch (json) {
    {'sha256': final String sha256} => switch (PictureRef.fromJson(
      json['picture'],
    )) {
      final picture? => SavedGif(picture: picture, sha256: sha256),
      null => null,
    },
    _ => null,
  };
}

/// GIFs saved on this device, newest first. The pictures live encrypted on
/// Blossom; this keeps their keys.
class GifBook {
  GifBook(this._store);

  static const max = 200;

  final SnapshotStore _store;
  final List<SavedGif> _gifs = [];

  List<SavedGif> get all => List.unmodifiable(_gifs);

  bool has(String sha256) => _gifs.any((g) => g.sha256 == sha256);

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {'gifs': final List<Object?> gifs}) {
      _gifs.addAll(gifs.map(SavedGif.fromJson).nonNulls);
    }
  }

  Future<void> add(SavedGif gif) async {
    _gifs
      ..removeWhere((g) => g.sha256 == gif.sha256)
      ..insert(0, gif);
    if (_gifs.length > max) _gifs.removeRange(max, _gifs.length);
    await _save();
  }

  Future<void> remove(String sha256) async {
    _gifs.removeWhere((g) => g.sha256 == sha256);
    await _save();
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'gifs': [for (final g in _gifs) g.toJson()],
    }),
  );

  Future<void> wipe() => _store.delete();
}
