import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/blossom.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/profiles.dart';

void main() {
  test('profile JSON round trips and clamps long names', () {
    final profile = Profile(
      updatedAt: 10,
      name: 'x' * 100,
      picture: const PictureRef(
        url: 'https://b/1',
        key: 'k',
        nonce: 'n',
        mime: 'image/png',
      ),
    );
    final decoded = Profile.decode(profile.encode())!;
    expect(decoded.name.length, 64);
    expect(decoded.picture?.url, 'https://b/1');
    expect(Profile.decode('not json'), isNull);
    expect(Profile.decode('{"name":"no date"}'), isNull);
  });

  test('pictures decrypt only with their key', () async {
    final bytes = Uint8List.fromList(List.generate(300, (i) => i % 251));
    final (sealed, finish) = await encryptPicture(bytes, 'image/jpeg');
    expect(sealed, isNot(bytes));
    final ref = finish('https://b/x');
    expect(await decryptPicture(sealed, ref), bytes);
    final other = PictureRef(
      url: ref.url,
      key: (await encryptPicture(bytes, 'image/jpeg')).$2('u').key,
      nonce: ref.nonce,
      mime: ref.mime,
    );
    await expectLater(decryptPicture(sealed, other), throwsA(anything));
  });

  test('book keeps the newest profile and tracks what was sent', () async {
    final store = MemorySnapshotStore();
    final book = ProfileBook(store, BlossomClient(servers: const []));
    expect(await book.put('a', const Profile(updatedAt: 5, name: 'new')), true);
    expect(
      await book.put('a', const Profile(updatedAt: 4, name: 'old')),
      false,
    );
    expect(book.of('a')?.name, 'new');

    final mine = await book.edit('me', name: '  Me  ');
    expect(mine.name, 'Me');
    expect(book.needsSending('friend', mine), isTrue);
    await book.markSent('friend', mine);
    expect(book.needsSending('friend', mine), isFalse);
    final edited = await book.edit('me', name: 'Me again');
    expect(edited.updatedAt, greaterThan(mine.updatedAt));
    expect(book.needsSending('friend', edited), isTrue);

    final reloaded = ProfileBook(store, BlossomClient(servers: const []));
    await reloaded.load();
    expect(reloaded.of('a')?.name, 'new');
    expect(reloaded.of('me')?.name, 'Me again');
    expect(reloaded.needsSending('friend', mine), isFalse);
  });
}
