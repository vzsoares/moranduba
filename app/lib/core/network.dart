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

/// [raw] as a TURN server URL (`turn:` added when no scheme), or null when
/// it is not one. The scheme comes out lowercase; query parameters such as
/// `?transport=tcp` stay.
String? turnUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  final scheme = RegExp(r'^turns?:', caseSensitive: false).firstMatch(text);
  text = scheme == null
      ? 'turn:$text'
      : '${scheme[0]!.toLowerCase()}${text.substring(scheme.end)}';
  final uri = Uri.tryParse(text.replaceFirst(':', '://'));
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return text;
}

/// A TURN server for call links that cannot connect directly (ADR 0003).
class TurnServer {
  const TurnServer({
    required this.url,
    required this.username,
    required this.credential,
  });

  final String url;
  final String username;
  final String credential;

  /// An RTCIceServer.
  Map<String, String> get ice => {
    'urls': url,
    'username': username,
    'credential': credential,
  };

  Map<String, String> toJson() => {
    'url': url,
    'username': username,
    'credential': credential,
  };

  static TurnServer? fromJson(Object? json) => switch (json) {
    {
      'url': final String raw,
      'username': final String username,
      'credential': final String credential,
    } =>
      switch (turnUrl(raw)) {
        final url? => TurnServer(
          url: url,
          username: username,
          credential: credential,
        ),
        null => null,
      },
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is TurnServer &&
      other.url == url &&
      other.username == username &&
      other.credential == credential;

  @override
  int get hashCode => Object.hash(url, username, credential);
}

/// The relays, Blossom and TURN servers this identity uses on this device;
/// null relays or Blossom servers mean the built-in defaults.
class NetworkBook {
  NetworkBook(this._store);

  final SnapshotStore _store;
  List<String>? relays;
  List<String>? blossom;
  List<TurnServer> turn = const [];

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case final Map<String, Object?> json) {
      relays = _list(json['relays'], relayUrl);
      blossom = _list(json['blossom'], blossomUrl);
      if (json['turn'] case final List<Object?> turn) {
        this.turn = [for (final item in turn) ?TurnServer.fromJson(item)];
      }
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

  /// Saves the lists; an empty relay or Blossom list goes back to the
  /// defaults.
  Future<void> save({
    required List<String> relays,
    required List<String> blossom,
    List<TurnServer>? turn,
  }) async {
    this.relays = relays.isEmpty ? null : relays;
    this.blossom = blossom.isEmpty ? null : blossom;
    if (turn != null) this.turn = List.unmodifiable(turn);
    await _store.write(
      jsonEncode({
        'relays': this.relays,
        'blossom': this.blossom,
        'turn': [for (final server in this.turn) server.toJson()],
      }),
    );
  }

  Future<void> wipe() => _store.delete();
}
