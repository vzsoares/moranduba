import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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

/// Saved GIFs stay under this.
const maxGifBytes = 8 * 1024 * 1024;

/// Downloads a GIF from [link]. Throws [FormatException] with a message
/// for people when it is not an http(s) link to a GIF under [maxGifBytes].
Future<Uint8List> fetchGif(String link, {http.Client? client}) async {
  final url = Uri.tryParse(link.trim());
  if (url == null ||
      !{'http', 'https'}.contains(url.scheme) ||
      url.host.isEmpty) {
    throw const FormatException('Paste a link that starts with https://');
  }
  final http.Response response;
  try {
    response = await (client ?? http.Client()).get(url);
  } on http.ClientException {
    // Browsers also land here when the site does not allow cross-origin use.
    throw const FormatException(
      'Could not download it. Some sites block that; save the GIF and use '
      'Add GIF instead.',
    );
  }
  if (response.statusCode != 200) {
    throw FormatException('The site answered ${response.statusCode}.');
  }
  final bytes = response.bodyBytes;
  if (bytes.length > maxGifBytes) {
    throw const FormatException('GIFs must be under 8 MB.');
  }
  if (bytes.length < 6 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'GIF8') {
    throw const FormatException('That link is not a GIF.');
  }
  return bytes;
}
