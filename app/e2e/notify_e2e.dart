// Browser check of message notifications. Run with E2E_NOTIFY=1 so the
// runner fakes a hidden tab and records Notification calls in
// window.morandubaNotified. Roles: alice sends, bob gets notified.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:moranduba/core/groups/groups.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/groups/mls_platform.dart';
import 'package:moranduba/core/groups/rust_group_engine.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';
import 'package:moranduba/ui/notifications/notifications.dart';

const _relays = ['ws://localhost:7777'];

final _params = Uri.base.queryParameters;
final _role = _params['role'] ?? 'alice';

@JS('morandubaNotified')
external JSArray<JSAny>? get _notified;

void _log(String line) => debugPrint('E2E $_role $line');

Future<void> _until(
  String what,
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<Session> _session() {
  final id = Identity.fromPrivateKey(_params['sk']!);
  return Session.start(
    id,
    relays: _relays,
    openStore: (_) async => MemorySnapshotStore(),
    openGroupEngine: () => RustGroupEngine.open(
      bridge: createMlsBridge(),
      secretKey: id.privateKey,
      storageKey: '33' * 32,
      store: MemorySnapshotStore(),
    ),
  );
}

List<Map<String, String>> _notifications() => [
  for (final item in _notified?.toDart ?? const <JSAny>[])
    if (item.dartify() case {
      'title': final String title,
      'body': final String body,
    })
      {'title': title, 'body': body},
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await (_role == 'alice' ? _alice() : _bob());
    _log('PASS');
  } catch (e, stack) {
    _log('FAIL $e\n$stack');
  }
}

Future<void> _alice() async {
  final peer = _params['peer']!;
  final session = await _session();
  await session.updateProfile(name: 'Alice');
  await _until('bob online', () async {
    try {
      await session.requestFriend(peer);
      return true;
    } catch (_) {
      return false;
    }
  });
  await _until('bob accepts', () => session.friends.contains(peer));
  await session.sendText(peer, 'ping from alice');
  await _until('bob key package', () async {
    try {
      final group = await session.groups!.create('news', [peer]);
      await _until(
        'bob joins',
        () => session.groups!.group(group.id)?.memberCount == 2,
      );
      await session.sendToGroup(group.id, 'hello group');
      return true;
    } on MissingKeyPackage {
      return false;
    }
  });
  // Stay until Bob has read everything.
  await Future<void>.delayed(const Duration(seconds: 8));
  await session.close();
}

Future<void> _bob() async {
  final peer = _params['peer']!;
  final session = await _session();
  final notices = showNotices(session);
  await _until('request', () => session.incomingRequests.contains(peer));
  await session.acceptFriend(peer);
  final groups = session.groups!;
  await _until('invite', () => groups.invites.isNotEmpty);
  await groups.accept(groups.invites.single.id);
  await _until('two notifications', () => _notifications().length >= 2);
  final got = _notifications();
  _log('notified $got');
  if (!got.any(
    (n) => n['title'] == 'Alice' && n['body'] == 'ping from alice',
  )) {
    throw StateError('no DM notification');
  }
  if (!got.any(
    (n) => n['title'] == 'Alice · news' && n['body'] == 'hello group',
  )) {
    throw StateError('no group notification');
  }
  await notices.cancel();
  await session.close();
}
