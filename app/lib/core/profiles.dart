import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'groups/blossom.dart';
import 'groups/mls_bridge.dart';

/// A picture encrypted with its own key; only people who got the profile
/// through an encrypted channel can see it.
class PictureRef {
  const PictureRef({
    required this.url,
    required this.key,
    required this.nonce,
    required this.mime,
  });

  final String url;
  final String key;
  final String nonce;
  final String mime;

  Map<String, String> toJson() => {
    'url': url,
    'key': key,
    'nonce': nonce,
    'mime': mime,
  };

  static PictureRef? fromJson(Object? json) => switch (json) {
    {
      'url': final String url,
      'key': final String key,
      'nonce': final String nonce,
      'mime': final String mime,
    } =>
      PictureRef(url: url, key: key, nonce: nonce, mime: mime),
    _ => null,
  };
}

class Profile {
  const Profile({required this.updatedAt, this.name = '', this.picture});

  /// Unix seconds; the newest version wins.
  final int updatedAt;
  final String name;
  final PictureRef? picture;

  Map<String, Object?> toJson() => {
    'v': 1,
    'updated_at': updatedAt,
    'name': name,
    'picture': picture?.toJson(),
  };

  static Profile? fromJson(Object? json) => switch (json) {
    {'updated_at': final int updatedAt, 'name': final String name} => Profile(
      updatedAt: updatedAt,
      name: name.length > 64 ? name.substring(0, 64) : name,
      picture: PictureRef.fromJson(json['picture']),
    ),
    _ => null,
  };

  String encode() => jsonEncode(toJson());

  static Profile? decode(String payload) {
    try {
      return fromJson(jsonDecode(payload));
    } on FormatException {
      return null;
    }
  }
}

final _aes = AesGcm.with256bits();

Future<(Uint8List, PictureRef Function(String url))> encryptPicture(
  Uint8List bytes,
  String mime,
) async {
  final key = await _aes.newSecretKey();
  final nonce = _aes.newNonce();
  final box = await _aes.encrypt(bytes, secretKey: key, nonce: nonce);
  final keyBytes = await key.extractBytes();
  return (
    Uint8List.fromList(box.concatenation(nonce: false)),
    (String url) => PictureRef(
      url: url,
      key: base64.encode(keyBytes),
      nonce: base64.encode(nonce),
      mime: mime,
    ),
  );
}

Future<Uint8List> decryptPicture(Uint8List sealed, PictureRef ref) async {
  final nonce = base64.decode(ref.nonce);
  final box = SecretBox.fromConcatenation(
    [...nonce, ...sealed],
    nonceLength: nonce.length,
    macLength: _aes.macAlgorithm.macLength,
  );
  final plain = await _aes.decrypt(
    box,
    secretKey: SecretKey(base64.decode(ref.key)),
  );
  return Uint8List.fromList(plain);
}

/// Everyone's profiles and who already has ours, kept on the device.
class ProfileBook {
  ProfileBook(this._store, this._blossom);

  final SnapshotStore _store;
  final BlossomClient _blossom;
  final Map<String, Profile> _profiles = {};

  /// Target (friend pubkey or group id) → version of ours they have.
  final Map<String, int> _sent = {};
  final Map<String, Future<Uint8List?>> _pictures = {};

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {
      'profiles': final Map<String, Object?> profiles,
      'sent': final Map<String, Object?> sent,
    }) {
      for (final MapEntry(:key, :value) in profiles.entries) {
        if (Profile.fromJson(value) case final profile?) {
          _profiles[key] = profile;
        }
      }
      for (final MapEntry(:key, :value) in sent.entries) {
        if (value is int) _sent[key] = value;
      }
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'profiles': {for (final e in _profiles.entries) e.key: e.value.toJson()},
      'sent': _sent,
    }),
  );

  Profile? of(String pubkey) => _profiles[pubkey];

  /// Stores [profile] for [pubkey] if newer. Returns whether it changed.
  Future<bool> put(String pubkey, Profile profile) async {
    final current = _profiles[pubkey];
    if (current != null && current.updatedAt >= profile.updatedAt) {
      return false;
    }
    _profiles[pubkey] = profile;
    _pictures.remove(pubkey)?.ignore();
    await _save();
    return true;
  }

  /// Uploads [picture] (encrypted) when given and returns the new profile.
  Future<Profile> edit(
    String me, {
    required String name,
    Uint8List? picture,
    String? mime,
    bool removePicture = false,
  }) async {
    var ref = removePicture ? null : _profiles[me]?.picture;
    if (picture != null && mime != null) {
      final (sealed, finish) = await encryptPicture(picture, mime);
      ref = finish(await _blossom.upload(sealed));
    }
    final profile = Profile(
      updatedAt: max(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        (_profiles[me]?.updatedAt ?? 0) + 1,
      ),
      name: name.trim(),
      picture: ref,
    );
    await put(me, profile);
    return profile;
  }

  bool needsSending(String target, Profile mine) =>
      (_sent[target] ?? -1) < mine.updatedAt;

  /// Drops earlier targets starting with [replacing], such as a group's
  /// previous epochs.
  Future<void> markSent(
    String target,
    Profile mine, {
    String? replacing,
  }) async {
    if (replacing != null) {
      _sent.removeWhere((key, _) => key.startsWith(replacing));
    }
    _sent[target] = mine.updatedAt;
    await _save();
  }

  /// The decrypted picture of [pubkey], fetched once per session.
  Future<Uint8List?> picture(String pubkey) {
    final ref = _profiles[pubkey]?.picture;
    if (ref == null) return Future.value();
    return _pictures[pubkey] ??= () async {
      try {
        return await decryptPicture(await _blossom.download(ref.url), ref);
      } catch (_) {
        _pictures.remove(pubkey)?.ignore();
        return null;
      }
    }();
  }

  Future<void> wipe() => _store.delete();
}
