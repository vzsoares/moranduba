import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore();

  // The data protection keychain needs a signed build with a keychain group.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class IdentityStore {
  const IdentityStore(this._store);

  static const _privateKey = 'identity.private_key';

  final SecretStore _store;

  Future<Identity?> load() async {
    final hex = await _store.read(_privateKey);
    return hex == null ? null : Identity.fromPrivateKey(hex);
  }

  Future<void> save(Identity identity) =>
      _store.write(_privateKey, identity.privateKey);

  Future<void> clear() => _store.delete(_privateKey);
}
