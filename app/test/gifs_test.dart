import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moranduba/core/gifs.dart';
import 'package:moranduba/core/giphy.dart';
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

  test('GIPHY results parse and skip malformed entries', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/gifs/search');
      expect(request.url.queryParameters['q'], 'cat');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'x1',
              'title': 'Cat',
              'images': {
                'fixed_width_small': {'url': 'https://media.giphy.com/s.gif'},
                'downsized': {
                  'url': 'https://media.giphy.com/d.gif',
                  'width': '320',
                  'height': '240',
                },
              },
            },
            {'id': 'broken'},
          ],
        }),
        200,
      );
    });
    final gifs = await Giphy(client: client).search('cat');
    expect(gifs.single.id, 'x1');
    expect(gifs.single.full, 'https://media.giphy.com/d.gif');
    expect((gifs.single.width, gifs.single.height), (320, 240));
  });
}
