import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'push.dart';

/// web/push_sw.js shows the notification; the page only subscribes.
bool get pushSupported =>
    web.window.isSecureContext &&
    globalContext.has('PushManager') &&
    web.window.navigator.has('serviceWorker');

Future<void> startPush(void Function(PushRing ring) onRing) async {}

/// A browser keeps one push subscription per service worker registration,
/// so each SFU (its own VAPID key) gets a registration of its own scope.
Future<PushTarget?> pushSubscribe(String sfu, String vapidKey) async {
  if (!pushSupported) return null;
  final registration = await web.window.navigator.serviceWorker
      .register(
        'push_sw.js'.toJS,
        web.RegistrationOptions(scope: 'push/${sfu.substring(0, 16)}/'),
      )
      .toDart;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (registration.active == null) {
    if (DateTime.now().isAfter(deadline)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final manager = registration.pushManager;
  final subscription =
      await manager.getSubscription().toDart ??
      await manager
          .subscribe(
            web.PushSubscriptionOptionsInit(
              userVisibleOnly: true,
              applicationServerKey: _decode(vapidKey).toJS,
            ),
          )
          .toDart;
  final p256dh = subscription.getKey('p256dh');
  final auth = subscription.getKey('auth');
  if (p256dh == null || auth == null) return null;
  return PushTarget(
    endpoint: subscription.endpoint,
    p256dh: _encode(p256dh),
    auth: _encode(auth),
  );
}

Uint8List _decode(String base64url) =>
    base64Url.decode(base64Url.normalize(base64url));

String _encode(JSArrayBuffer buffer) =>
    base64Url.encode(buffer.toDart.asUint8List()).replaceAll('=', '');
