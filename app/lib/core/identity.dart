import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';

final _hexKey = RegExp(r'^[0-9a-f]{64}$');

class Identity {
  const Identity({required this.privateKey, required this.publicKey});

  factory Identity.generate() {
    final pair = Bip340.generatePrivateKey();
    return Identity.fromPrivateKey(pair.privateKey!);
  }

  factory Identity.fromPrivateKey(String privateKeyHex) => Identity(
    privateKey: privateKeyHex,
    publicKey: Bip340.getPublicKey(privateKeyHex),
  );

  /// Accepts an `nsec1…` string or a 64-char hex private key.
  factory Identity.parse(String input) {
    final value = input.trim();
    if (value.startsWith('nsec1')) {
      return Identity.fromPrivateKey(_decodeBech32(value));
    }
    final hex = value.toLowerCase();
    if (_hexKey.hasMatch(hex)) return Identity.fromPrivateKey(hex);
    throw const FormatException('Expected an nsec or a 64-character hex key');
  }

  final String privateKey;
  final String publicKey;

  String get npub => Nip19.encodePubKey(publicKey);
  String get nsec => Nip19.encodePrivateKey(privateKey);
}

/// Accepts `npub1…`, `nprofile1…` or 64-char hex; returns the hex pubkey.
String parsePublicKey(String input) {
  final value = input.trim();
  if (value.startsWith('npub1')) return _decodeBech32(value);
  if (value.startsWith('nprofile1')) {
    return _checked(Nip19.decodeNprofile(value).pubkey);
  }
  final hex = value.toLowerCase();
  if (_hexKey.hasMatch(hex)) return hex;
  throw const FormatException('Expected an npub or a 64-character hex key');
}

String shortKey(String hexPubkey) {
  final npub = Nip19.encodePubKey(hexPubkey);
  return '${npub.substring(0, 12)}…${npub.substring(npub.length - 6)}';
}

String _decodeBech32(String value) {
  try {
    return _checked(Nip19.decode(value));
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Invalid bech32 key');
  }
}

String _checked(String hex) {
  if (!_hexKey.hasMatch(hex)) throw const FormatException('Invalid key');
  return hex;
}
