import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Minimal BUD-01/02 server: `PUT /upload` stores, `GET /<sha256>` serves.
class FakeBlossom {
  FakeBlossom._(this._server);

  static Future<FakeBlossom> start() async {
    final blossom = FakeBlossom._(await HttpServer.bind('127.0.0.1', 0));
    blossom._server.listen(blossom._handle);
    return blossom;
  }

  final HttpServer _server;
  final Map<String, Uint8List> blobs = {};
  final List<Map<String, Object?>> authEvents = [];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'PUT' && request.uri.path == '/upload') {
      final auth = request.headers.value('authorization') ?? '';
      if (!auth.startsWith('Nostr ')) {
        response.statusCode = 401;
        return response.close();
      }
      final event = jsonDecode(utf8.decode(base64.decode(auth.substring(6))));
      if (event case final Map<String, Object?> map) authEvents.add(map);
      final body = await request.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final bytes = body.takeBytes();
      final hash = sha256.convert(bytes).toString();
      blobs[hash] = bytes;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'url': '$url/$hash', 'sha256': hash}));
      return response.close();
    }
    final blob = blobs[request.uri.path.replaceFirst('/', '')];
    if (request.method == 'GET' && blob != null) {
      response.add(blob);
      return response.close();
    }
    response.statusCode = 404;
    return response.close();
  }
}
