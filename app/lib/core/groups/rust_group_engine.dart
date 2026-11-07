import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../identity.dart';
import '../identity_store.dart';
import 'group_engine.dart';
import 'mls_bridge.dart';
import 'mls_platform.dart';

class MlsException implements Exception {
  const MlsException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => 'MlsException($method): $message';
}

/// Opens [identity]'s engine with its snapshot and storage key, creating
/// both on first use.
Future<GroupEngine> openGroupEngine(
  Identity identity,
  SecretStore secrets,
) async {
  final keyName = 'mls.storage_key.${identity.publicKey}';
  var storageKey = await secrets.read(keyName);
  if (storageKey == null) {
    final random = Random.secure();
    storageKey = [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await secrets.write(keyName, storageKey);
  }
  return RustGroupEngine.open(
    bridge: createMlsBridge(),
    secretKey: identity.privateKey,
    storageKey: storageKey,
    store: await openSnapshotStore(identity.publicKey),
    onWipe: () => secrets.delete(keyName),
  );
}

/// [GroupEngine] backed by the Rust crate in `rust/`.
///
/// The engine keeps state in memory; after every change it hands back an
/// encrypted snapshot that goes to [SnapshotStore].
class RustGroupEngine implements GroupEngine {
  RustGroupEngine._(this._bridge, this._handle, this._store, this._onWipe);

  static Future<RustGroupEngine> open({
    required MlsBridge bridge,
    required String secretKey,
    required String storageKey,
    required SnapshotStore store,
    Future<void> Function()? onWipe,
  }) async {
    await bridge.ready();
    final args = jsonEncode({
      'secret_key': secretKey,
      'storage_key': storageKey,
      'snapshot': await store.read(),
    });
    final handle = _decode('open', bridge.call(0, 'open', args));
    if (handle is! int) throw const FormatException('open returned no handle');
    return RustGroupEngine._(bridge, handle, store, onWipe);
  }

  final MlsBridge _bridge;
  final int _handle;
  final SnapshotStore _store;
  final Future<void> Function()? _onWipe;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  bool _closed = false;

  @override
  Future<String> signedKeyPackage(List<String> relays) async {
    final event = _string(_call('key_package', {'relays': relays}));
    await _saveNow();
    return event;
  }

  @override
  Future<GroupCreated> create({
    required String name,
    required List<String> relays,
    required List<String> memberKeyPackages,
  }) async {
    final reply = _call('create_group', {
      'name': name,
      'relays': relays,
      'key_packages': memberKeyPackages,
    });
    await _saveNow();
    return switch (reply) {
      {'group': final group, 'welcomes': final welcomes} => GroupCreated(
        group: _group(group),
        welcomeRumors: _strings(welcomes),
      ),
      _ => throw FormatException('create_group: $reply'),
    };
  }

  @override
  Future<MembersAdded> addMembers(
    String groupId,
    List<String> keyPackages,
  ) async {
    final reply = _call('add_members', {
      'group_id': groupId,
      'key_packages': keyPackages,
    });
    await _saveNow();
    return switch (reply) {
      {'commit': final String commit, 'welcomes': final welcomes} =>
        MembersAdded(commit: commit, welcomeRumors: _strings(welcomes)),
      _ => throw FormatException('add_members: $reply'),
    };
  }

  @override
  Future<void> receiveWelcome(String wrapperId, String rumorJson) async {
    _call('process_welcome', {'wrapper_id': wrapperId, 'rumor': rumorJson});
    _saveSoon();
  }

  @override
  Future<List<GroupInvite>> invites() async => [
    for (final invite in _list(_call('invites')))
      switch (invite) {
        {
          'id': final String id,
          'group_name': final String groupName,
          'inviter': final String inviter,
          'member_count': final int memberCount,
        } =>
          GroupInvite(
            id: id,
            groupName: groupName,
            inviter: inviter,
            memberCount: memberCount,
          ),
        _ => throw FormatException('invite: $invite'),
      },
  ];

  @override
  Future<void> acceptInvite(String inviteId) async {
    _call('accept', {'id': inviteId});
    await _saveNow();
  }

  @override
  Future<void> declineInvite(String inviteId) async {
    _call('decline', {'id': inviteId});
    await _saveNow();
  }

  @override
  Future<List<GroupInfo>> groups() async => [
    for (final group in _list(_call('groups'))) _group(group),
  ];

  @override
  Future<List<String>> members(String groupId) async =>
      _strings(_call('members', {'group_id': groupId}));

  /// Saved before returning: a lost send ratchet step would reuse a key.
  @override
  Future<String> encryptText(
    String groupId,
    String text, {
    int? expiresAt,
  }) async {
    final event = _string(
      _call('encrypt_text', {
        'group_id': groupId,
        'text': text,
        'expires_at': ?expiresAt,
      }),
    );
    await _saveNow();
    return event;
  }

  @override
  Future<int> prune(String groupId, int before) async {
    final deleted = switch (_call('prune', {
      'group_id': groupId,
      'before': before,
    })) {
      final int n => n,
      final other => throw FormatException('prune: $other'),
    };
    if (deleted > 0) await _saveNow();
    return deleted;
  }

  @override
  Future<GroupReceipt> receive(String eventJson) async {
    final reply = _call('receive', {'event': eventJson});
    _saveSoon();
    return switch (reply) {
      final Map<String, Object?> r => GroupReceipt(
        groupId: switch (r['group_id']) {
          final String id => id,
          _ => null,
        },
        message: r['message'] == null ? null : _message(r['message']),
        signal: switch (r) {
          {
            'group_id': final String groupId,
            'signal': {
              'id': final String id,
              'sender': final String sender,
              'payload': final String payload,
              'created_at': final int createdAt,
            },
          } =>
            GroupSignal(
              id: id,
              groupId: groupId,
              sender: sender,
              payload: payload,
              createdAt: createdAt,
            ),
          _ => null,
        },
        publish: switch (r['publish']) {
          final String event => event,
          _ => null,
        },
      ),
      _ => throw FormatException('receive: $reply'),
    };
  }

  @override
  Future<void> merge(String groupId) async {
    _call('merge', {'group_id': groupId});
    await _saveNow();
  }

  @override
  Future<EncryptedMedia> encryptMedia(
    String groupId,
    Uint8List data, {
    required String mime,
    required String filename,
  }) async {
    final reply = _call('encrypt_media', {
      'group_id': groupId,
      'data': base64.encode(data),
      'mime': mime,
      'filename': filename,
    });
    return switch (reply) {
      {
        'encrypted': final String encrypted,
        'upload': final Map<String, Object?> upload,
      } =>
        EncryptedMedia(data: base64.decode(encrypted), upload: upload),
      _ => throw FormatException('encrypt_media: $reply'),
    };
  }

  /// Saved before returning, like [encryptText].
  @override
  Future<String> sendMedia(
    String groupId, {
    required String caption,
    required String url,
    required Map<String, Object?> upload,
    int? expiresAt,
  }) async {
    final event = _string(
      _call('send_media', {
        'group_id': groupId,
        'caption': caption,
        'url': url,
        'upload': upload,
        'expires_at': ?expiresAt,
      }),
    );
    await _saveNow();
    return event;
  }

  @override
  Future<Uint8List> decryptMedia(
    String groupId,
    Uint8List data,
    MediaRef media,
  ) async => base64.decode(
    _string(
      _call('decrypt_media', {
        'group_id': groupId,
        'data': base64.encode(data),
        'media': media.toJson(),
      }),
    ),
  );

  /// Saved before returning, like [encryptText].
  @override
  Future<String> sendSignal(String groupId, String payload) async {
    final event = _string(
      _call('send_signal', {'group_id': groupId, 'payload': payload}),
    );
    await _saveNow();
    return event;
  }

  @override
  Future<ExportedSecret> exportSecret(
    String groupId, {
    required String label,
    required String context,
    int length = 32,
  }) async {
    final reply = _call('export_secret', {
      'group_id': groupId,
      'label': label,
      'context': context,
      'length': length,
    });
    return switch (reply) {
      {'secret': final String secret, 'epoch': final int epoch} =>
        ExportedSecret(secret: _hexBytes(secret), epoch: epoch),
      _ => throw FormatException('export_secret: $reply'),
    };
  }

  @override
  Future<List<GroupMessage>> messages(String groupId) async => [
    for (final m in _list(_call('messages', {'group_id': groupId})))
      _message(m),
  ];

  @override
  Future<List<String>> leave(String groupId) async {
    final events = _strings(_call('leave', {'group_id': groupId}));
    await _saveNow();
    return events;
  }

  @override
  Future<void> wipe() async {
    await close();
    await _store.delete();
    await _onWipe?.call();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_saveTimer != null) await _saveNow();
    await _writes;
    _call('close');
    _closed = true;
  }

  Object? _call(String method, [Object? args]) {
    if (_closed) throw StateError('MLS engine is closed');
    final encoded = args == null ? '' : jsonEncode(args);
    return _decode(method, _bridge.call(_handle, method, encoded));
  }

  static Object? _decode(String method, String reply) =>
      switch (jsonDecode(reply)) {
        {'ok': final value} => value,
        {'err': final String message} => throw MlsException(method, message),
        _ => throw FormatException('Bad reply to $method: $reply'),
      };

  /// Snapshots now and queues the write behind earlier ones.
  Future<void> _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final snapshot = _string(_call('snapshot'));
    return _writes = _writes.then((_) => _store.write(snapshot));
  }

  /// Coalesces bursts, such as relay history replay, into one write.
  void _saveSoon() {
    _saveTimer ??= Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_saveNow()),
    );
  }
}

GroupInfo _group(Object? json) => switch (json) {
  {
    'id': final String id,
    'nostr_group_id': final String nostrGroupId,
    'name': final String name,
    'relays': final relays,
    'admins': final admins,
    'member_count': final int memberCount,
    'last_message_at': final int? lastMessageAt,
    'epoch': final int epoch,
  } =>
    GroupInfo(
      id: id,
      nostrGroupId: nostrGroupId,
      name: name,
      relays: _strings(relays),
      admins: _strings(admins),
      memberCount: memberCount,
      epoch: epoch,
      lastMessageAt: lastMessageAt,
    ),
  _ => throw FormatException('group: $json'),
};

GroupMessage _message(Object? json) => switch (json) {
  {
    'id': final String id,
    'group_id': final String groupId,
    'sender': final String sender,
    'text': final String text,
    'created_at': final int createdAt,
    'media': final media,
  } =>
    GroupMessage(
      id: id,
      groupId: groupId,
      sender: sender,
      text: text,
      createdAt: createdAt,
      media: [for (final m in _list(media)) _media(m)],
    ),
  _ => throw FormatException('message: $json'),
};

MediaRef _media(Object? json) => switch (json) {
  {
    'url': final String url,
    'original_hash': final String originalHash,
    'mime': final String mime,
    'filename': final String filename,
    'nonce': final String nonce,
    'version': final String version,
    'width': final int? width,
    'height': final int? height,
  } =>
    MediaRef(
      url: url,
      originalHash: originalHash,
      mime: mime,
      filename: filename,
      nonce: nonce,
      version: version,
      width: width,
      height: height,
    ),
  _ => throw FormatException('media: $json'),
};

Uint8List _hexBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _string(Object? json) => switch (json) {
  final String value => value,
  _ => throw FormatException('expected a string, got $json'),
};

List<Object?> _list(Object? json) => switch (json) {
  final List<Object?> values => values,
  _ => throw FormatException('expected a list, got $json'),
};

List<String> _strings(Object? json) => [
  for (final value in _list(json)) _string(value),
];
