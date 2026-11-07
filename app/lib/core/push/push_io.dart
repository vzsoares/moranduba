import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'push.dart';

/// Android receives through UnifiedPush, from the distributor the user
/// installed (ntfy, for one). Other native platforms have no push here.
bool get pushSupported => Platform.isAndroid;

final Map<String, Completer<PushTarget?>> _pending = {};
bool _started = false;
void Function(PushRing ring)? _onRing;

/// Listens for pushes in this isolate. UnifiedPush runs `main` with
/// `--unifiedpush-bg` when a push arrives while the app is closed.
Future<void> startPush(void Function(PushRing ring) onRing) async {
  _onRing = onRing;
  if (!pushSupported || _started) return;
  _started = true;
  try {
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) {
        final keys = endpoint.pubKeySet;
        _pending
            .remove(instance)
            ?.complete(
              keys == null
                  ? null
                  : PushTarget(
                      endpoint: endpoint.url,
                      p256dh: keys.pubKey,
                      auth: keys.auth,
                    ),
            );
      },
      onRegistrationFailed: (_, instance) =>
          _pending.remove(instance)?.complete(null),
      onMessage: (message, _) {
        if (!message.decrypted) return;
        final ring = PushRing.decode(utf8.decode(message.content));
        if (ring != null) _onRing?.call(ring);
      },
    );
  } catch (e) {
    debugPrint('push: $e');
  }
}

/// Registers with the distributor for [sfu]; null without a distributor.
Future<PushTarget?> pushSubscribe(String sfu, String vapidKey) async {
  if (!_started) return null;
  if (!await UnifiedPush.tryUseCurrentOrDefaultDistributor()) return null;
  final pending = _pending[sfu] = Completer<PushTarget?>();
  await UnifiedPush.register(instance: sfu, vapid: vapidKey);
  return pending.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () {
      _pending.remove(sfu);
      return null;
    },
  );
}
