import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/blossom.dart';

import '../support/fake_blossom.dart';

void main() {
  late FakeBlossom server;

  setUp(() async => server = await FakeBlossom.start());
  tearDown(() => server.close());

  test('uploads with a one-off key and downloads by hash', () async {
    final client = BlossomClient(servers: [server.url]);
    final data = Uint8List.fromList(List.generate(300, (i) => i % 256));

    final first = await client.upload(data);
    await client.upload(data);
    expect(await client.download(first), data);

    final [a, b] = server.authEvents;
    expect(a['kind'], 24242);
    expect(a['tags'], contains(equals(['x', sha256.convert(data).toString()])));
    expect(a['pubkey'], isNot(b['pubkey']));
  });

  test('falls through to the next server and rejects tampered blobs', () async {
    final client = BlossomClient(servers: ['http://127.0.0.1:1', server.url]);
    final url = await client.upload(Uint8List.fromList([1, 2, 3]));

    server.blobs[url.split('/').last] = Uint8List.fromList([9, 9, 9]);
    await expectLater(client.download(url), throwsA(isA<BlossomException>()));
  });

  test(
    'keeps two copies and fetches from the other when one is gone',
    () async {
      final mirror = await FakeBlossom.start();
      addTearDown(mirror.close);
      final client = BlossomClient(servers: [server.url, mirror.url]);
      final data = Uint8List.fromList([4, 5, 6, 7]);
      final hash = sha256.convert(data).toString();

      final url = await client.upload(data);
      expect(url, startsWith(server.url));
      expect(mirror.blobs.keys, contains(hash));

      server.blobs.clear();
      expect(await client.download(url), data);
    },
  );
}
