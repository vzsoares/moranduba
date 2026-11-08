import 'package:flutter_test/flutter_test.dart';
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
}
