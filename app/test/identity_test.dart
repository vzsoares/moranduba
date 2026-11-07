import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/identity_store.dart';

// Vectors from NIP-19.
const _npub = 'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
const _pubHex =
    '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
const _nsec = 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
const _privHex =
    '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';

class _MemoryStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  group('Identity', () {
    test('parses nsec and hex to the same key', () {
      final fromNsec = Identity.parse(_nsec);
      final fromHex = Identity.parse(' ${_privHex.toUpperCase()} ');
      expect(fromNsec.privateKey, _privHex);
      expect(fromHex.privateKey, _privHex);
      expect(fromNsec.nsec, _nsec);
      expect(fromNsec.publicKey, fromHex.publicKey);
    });

    test('generated keys round-trip through nsec', () {
      final identity = Identity.generate();
      expect(Identity.parse(identity.nsec).publicKey, identity.publicKey);
      expect(parsePublicKey(identity.npub), identity.publicKey);
    });

    test('rejects garbage', () {
      expect(() => Identity.parse('hello'), throwsFormatException);
      expect(() => Identity.parse('nsec1notreal'), throwsFormatException);
      expect(() => Identity.parse(_npub), throwsFormatException);
    });
  });

  group('parsePublicKey', () {
    test('accepts npub and hex', () {
      expect(parsePublicKey(_npub), _pubHex);
      expect(parsePublicKey(_pubHex), _pubHex);
    });

    test('rejects nsec and garbage', () {
      expect(() => parsePublicKey(_nsec), throwsFormatException);
      expect(() => parsePublicKey('npub1xyz'), throwsFormatException);
      expect(() => parsePublicKey('abc'), throwsFormatException);
    });
  });

  test('IdentityStore saves, loads and clears', () async {
    final store = IdentityStore(_MemoryStore());
    expect(await store.load(), isNull);
    await store.save(Identity.parse(_nsec));
    expect((await store.load())?.privateKey, _privHex);
    await store.clear();
    expect(await store.load(), isNull);
  });
}
