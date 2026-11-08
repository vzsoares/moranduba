import 'dart:convert';

import 'groups/mls_bridge.dart';

/// [raw] as a relay URL (`wss://` added when no scheme), or null when it is
/// not one.
String? relayUrl(String raw) => _url(raw, const {'wss', 'ws'}, 'wss');

/// [raw] as a Blossom server URL (`https://` added when no scheme), or null
/// when it is not one.
String? blossomUrl(String raw) => _url(raw, const {'https', 'http'}, 'https');

String? _url(String raw, Set<String> schemes, String fallback) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = '$fallback://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !schemes.contains(uri.scheme) || uri.host.isEmpty) {
    return null;
  }
  final path = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return uri.replace(path: path).toString();
}

/// The relays and Blossom servers this identity uses on this device; null
/// means the built-in defaults.
class NetworkBook {
  NetworkBook(this._store);

  final SnapshotStore _store;
  List<String>? relays;
  List<String>? blossom;

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case final Map<String, Object?> json) {
      relays = _list(json['relays'], relayUrl);
      blossom = _list(json['blossom'], blossomUrl);
    }
  }

  static List<String>? _list(Object? json, String? Function(String) parse) {
    if (json is! List<Object?>) return null;
    final urls = [
      for (final item in json)
        if (item is String) ?parse(item),
    ];
    return urls.isEmpty ? null : urls;
  }

  /// Saves both lists; an empty one goes back to the defaults.
  Future<void> save({
    required List<String> relays,
    required List<String> blossom,
  }) async {
    this.relays = relays.isEmpty ? null : relays;
    this.blossom = blossom.isEmpty ? null : blossom;
    await _store.write(
      jsonEncode({'relays': this.relays, 'blossom': this.blossom}),
    );
  }

  Future<void> wipe() => _store.delete();
}
