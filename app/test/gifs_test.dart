import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moranduba/core/gifs.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/profiles.dart';

SavedGif _gif(String hash) => SavedGif(
  picture: PictureRef(
    url: 'https://blossom.example/$hash',
    key: 'k',
    nonce: 'n',
    mime: 'image/gif',
  ),
  sha256: hash,
);

void main() {
  test('saved GIFs go newest first, once each, and survive a reload', () async {
    final store = MemorySnapshotStore();
    final book = GifBook(store);
    await book.add(_gif('a'));
    await book.add(_gif('b'));
    await book.add(_gif('a'));
    expect([for (final g in book.all) g.sha256], ['a', 'b']);

    await book.remove('b');
    final reloaded = GifBook(store);
    await reloaded.load();
    expect([for (final g in reloaded.all) g.sha256], ['a']);
    expect(reloaded.all.single.picture.mime, 'image/gif');
  });

  test('the collection keeps the newest ${GifBook.max}', () async {
    final book = GifBook(MemorySnapshotStore());
    for (var i = 0; i < GifBook.max + 5; i++) {
      await book.add(_gif('$i'));
    }
    expect(book.all.length, GifBook.max);
    expect(book.all.first.sha256, '${GifBook.max + 4}');
  });

  test('GIF links must be http(s), a GIF, and under the cap', () async {
    final gif = Uint8List.fromList([...'GIF89a'.codeUnits, 0, 0]);
    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/ok.gif' => http.Response.bytes(gif, 200),
        '/page' => http.Response('<html>', 200),
        '/big.gif' => http.Response.bytes(
          Uint8List(maxGifBytes + 1)..setAll(0, gif),
          200,
        ),
        _ => http.Response('', 404),
      },
    );
    expect(await fetchGif(' https://x.example/ok.gif ', client: client), gif);
    for (final (link, message) in [
      ('ftp://x.example/a.gif', 'https://'),
      ('https://x.example/page', 'not a GIF'),
      ('https://x.example/big.gif', '8 MB'),
      ('https://x.example/gone.gif', '404'),
    ]) {
      await expectLater(
        fetchGif(link, client: client),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
    }
  });
}
