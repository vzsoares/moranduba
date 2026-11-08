import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ndk/ndk.dart';

import '../identity.dart';

const _blossomServers = String.fromEnvironment('MORANDUBA_BLOSSOM');

/// Blossom servers for attachments, tried in order. They must accept opaque
/// blobs: some (Primal, nostrcheck) sniff content and refuse ciphertext.
/// Override with `--dart-define=MORANDUBA_BLOSSOM=https://…,…`.
List<String> get defaultBlossomServers => _blossomServers.isEmpty
    ? const [
        'https://nostr.download',
        'https://blossom.yakihonne.com',
        'https://files.sovbit.host',
      ]
    : _blossomServers.split(',').map((url) => url.trim()).toList();

class BlossomException implements Exception {
  const BlossomException(this.message);

  final String message;

  @override
  String toString() => 'BlossomException: $message';
}

/// Uploads and fetches blobs (BUD-01, BUD-02). Blobs are already encrypted,
/// and each upload is authorized by a throwaway key so servers can't link
/// uploads to an identity.
class BlossomClient {
  BlossomClient({List<String>? servers, http.Client? client})
    : servers = servers ?? defaultBlossomServers,
      _client = client ?? http.Client();

  final List<String> servers;
  final http.Client _client;

  /// Servers that keep each blob, so losing one loses nothing.
  static const copies = 2;

  /// Puts the blob on [copies] servers, in parallel and in list order;
  /// returns the URL from the first that took it.
  Future<String> upload(Uint8List data) async {
    final hash = sha256.convert(data).toString();
    final errors = <String>[];
    final urls = <String>[];
    var next = 0;
    while (urls.length < copies && next < servers.length) {
      final batch = servers.skip(next).take(copies - urls.length).toList();
      next += batch.length;
      final placed = await Future.wait([
        for (final server in batch) _put(server, data, hash, errors),
      ]);
      urls.addAll(placed.nonNulls);
    }
    if (urls.isEmpty) {
      throw BlossomException('Upload failed. ${errors.join('; ')}');
    }
    return urls.first;
  }

  Future<String?> _put(
    String server,
    Uint8List data,
    String hash,
    List<String> errors,
  ) async {
    try {
      final response = await _client.put(
        Uri.parse(server).resolve('/upload'),
        headers: {
          'Authorization': await _authorization(hash),
          'Content-Type': 'application/octet-stream',
        },
        body: data,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (jsonDecode(response.body) case {'url': final String url}) {
          return url;
        }
        errors.add('$server: no url in reply');
      } else {
        final reason = response.headers['x-reason'];
        errors.add(
          '$server: HTTP ${response.statusCode}'
          '${reason == null ? '' : ' ($reason)'}',
        );
      }
    } catch (e) {
      errors.add('$server: $e');
    }
    return null;
  }

  /// Fetches a blob and checks it against the hash in its URL. When that
  /// server fails, asks the other servers for the same hash (BUD-01).
  Future<Uint8List> download(String url) async {
    final hash = RegExp(r'[0-9a-f]{64}').firstMatch(url)?.group(0);
    final candidates = [
      url,
      if (hash != null)
        for (final server in servers)
          if (!url.startsWith(server))
            Uri.parse(server).resolve('/$hash').toString(),
    ];
    Object? first;
    for (final candidate in candidates) {
      try {
        return await _get(candidate, hash);
      } catch (e) {
        first ??= e;
      }
    }
    throw first ?? BlossomException('Nothing to fetch for $url');
  }

  Future<Uint8List> _get(String url, String? hash) async {
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw BlossomException('HTTP ${response.statusCode} for $url');
    }
    final bytes = response.bodyBytes;
    if (hash != null && sha256.convert(bytes).toString() != hash) {
      throw BlossomException('Blob does not match its hash: $url');
    }
    return bytes;
  }

  Future<String> _authorization(String hash) async {
    final key = Identity.generate();
    final expiration = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final event =
        await Bip340EventSigner(
          privateKey: key.privateKey,
          publicKey: key.publicKey,
        ).sign(
          Nip01Event(
            pubKey: key.publicKey,
            kind: 24242,
            content: 'Upload attachment',
            tags: [
              ['t', 'upload'],
              ['x', hash],
              ['expiration', '$expiration'],
            ],
          ),
        );
    final json = Nip01EventModel.fromEntity(event).toJsonString();
    return 'Nostr ${base64.encode(utf8.encode(json))}';
  }
}
