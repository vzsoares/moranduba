import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

class SfuException implements Exception {
  const SfuException(this.message);

  final String message;

  @override
  String toString() => 'SfuException: $message';
}

/// Requests to Moranduba SFUs over Nostr gift wraps (ADR 0002).
class SfuClient {
  SfuClient(this._ndk, {required this.me, required this.relays});

  /// Ephemeral outer kind, so relays forward without storing.
  static const wrapKind = 21059;
  static const rumorKind = 25051;
  static const sealKind = 13;

  final Ndk _ndk;
  final String me;
  final List<String> relays;
  final Map<String, ({String sfu, Completer<Map<String, Object?>> reply})>
  _pending = {};
  final _verifier = Bip340EventVerifier();
  final _random = Random.secure();
  StreamSubscription<Nip01Event>? _inbox;
  String? _subscriptionId;

  void start() {
    if (_inbox != null) return;
    final response = _ndk.requests.subscription(
      filter: Filter(kinds: [wrapKind], pTags: [me]),
      explicitRelays: relays,
      cacheRead: false,
      cacheWrite: false,
    );
    _subscriptionId = response.requestId;
    _inbox = response.stream.listen((event) => unawaited(_onWrap(event)));
  }

  /// Sends [message] to [sfu] and waits for the reply that echoes its id.
  /// Throws [SfuException] on an `error` reply or no reply in time.
  Future<Map<String, Object?>> request(
    String sfu,
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    start();
    final id = _newId();
    final reply = Completer<Map<String, Object?>>();
    _pending[id] = (sfu: sfu, reply: reply);
    try {
      await _send(sfu, {...message, 'id': id});
      final answer = await reply.future.timeout(
        timeout,
        onTimeout: () => throw SfuException(
          'No answer from the call server. Check that it is running and '
          'listens on one of your relays: ${relays.join(', ')}',
        ),
      );
      if (answer case {'type': 'error', 'message': final String error}) {
        throw SfuException(error);
      }
      return answer;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _send(String sfu, Map<String, Object?> message) async {
    final rumor = await _ndk.giftWrap.createRumor(
      content: jsonEncode(message),
      kind: rumorKind,
      tags: [
        ['p', sfu],
      ],
    );
    final seal = await _ndk.giftWrap.sealRumor(
      rumor: rumor,
      recipientPubkey: sfu,
    );
    final ephemeral = _ndk.giftWrap.eventSignerFactory.createWithNewKeyPair();
    final content = await ephemeral.encryptNip44(
      plaintext: Nip01EventModel.fromEntity(seal).toJsonString(),
      recipientPubKey: sfu,
    );
    if (content == null) throw const SfuException('Could not encrypt');
    final wrap = await ephemeral.sign(
      Nip01Event(
        pubKey: ephemeral.getPublicKey(),
        kind: wrapKind,
        tags: [
          ['p', sfu],
        ],
        content: content,
      ),
    );
    final responses = await _ndk.broadcast
        .broadcast(nostrEvent: wrap, specificRelays: relays)
        .broadcastDoneFuture;
    if (!responses.any((r) => r.broadcastSuccessful)) {
      throw const SfuException('No relay took the request');
    }
  }

  Future<void> _onWrap(Nip01Event wrap) async {
    try {
      final signer = _ndk.accounts.getLoggedAccount()?.signer;
      if (signer == null) return;
      final sealJson = await signer.decryptNip44(
        ciphertext: wrap.content,
        senderPubKey: wrap.pubKey,
      );
      if (sealJson == null) return;
      final seal = switch (jsonDecode(sealJson)) {
        final Map<String, Object?> map => Nip01EventModel.fromJson(map),
        _ => null,
      };
      if (seal == null ||
          seal.kind != sealKind ||
          !await _verifier.verify(seal)) {
        return;
      }
      final rumorJson = await signer.decryptNip44(
        ciphertext: seal.content,
        senderPubKey: seal.pubKey,
      );
      if (rumorJson == null) return;
      if (jsonDecode(rumorJson)
          case {
            'pubkey': final String author,
            'kind': rumorKind,
            'content': final String content,
          }
          when author == seal.pubKey) {
        if (jsonDecode(content)
            case {'reply_to': final String id} &&
                final Map<String, Object?> message) {
          final pending = _pending[id];
          if (pending == null || pending.sfu != seal.pubKey) return;
          if (!pending.reply.isCompleted) pending.reply.complete(message);
        }
      }
    } catch (e) {
      debugPrint('sfu reply ${wrap.id}: $e');
    }
  }

  String _newId() =>
      [for (var i = 0; i < 12; i++) _random.nextInt(256).toRadixString(16)]
          .join();

  Future<void> close() async {
    await _inbox?.cancel();
    _inbox = null;
    final id = _subscriptionId;
    if (id != null) await _ndk.requests.closeSubscription(id);
    for (final pending in _pending.values) {
      if (!pending.reply.isCompleted) {
        pending.reply.completeError(const SfuException('Closed'));
      }
    }
    _pending.clear();
  }
}
