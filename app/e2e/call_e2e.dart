// Browser end-to-end check of encrypted calls. The runner (e2e/run.ts) opens
// one page per participant: ?role=alice|bob&sk=<hex>&peer=<hex pubkey>.
// Each page logs "E2E <role> PASS" or "E2E <role> FAIL …".
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:moranduba/core/calls/group_call.dart';
import 'package:moranduba/core/groups/group_engine.dart';
import 'package:moranduba/core/groups/groups.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/groups/mls_platform.dart';
import 'package:moranduba/core/groups/rust_group_engine.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';
import 'package:moranduba/ui/call_page.dart';
import 'package:moranduba/ui/theme.dart';

const _relays = ['ws://localhost:7777'];

final _params = Uri.base.queryParameters;
final _role = _params['role'] ?? 'alice';

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

Future<int> _framesFrom(GroupCall call, String peer) async {
  final links = (await call.stats())['links'];
  if (links is! Map) return 0;
  return switch (links[peer]) {
    {'framesDecoded': final int frames} => frames,
    _ => 0,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await (_role == 'alice' ? _alice() : _bob());
    _log('PASS');
  } catch (e, stack) {
    _log('FAIL $e\n$stack');
  }
}

Future<Session> _session() {
  final id = Identity.fromPrivateKey(_params['sk']!);
  return Session.start(
    id,
    relays: _relays,
    openGroupEngine: () => RustGroupEngine.open(
      bridge: createMlsBridge(),
      secretKey: id.privateKey,
      storageKey: '22' * 32,
      store: MemorySnapshotStore(),
    ),
  );
}

/// The real call page; Chrome decodes remote video only while it renders.
void _show(Session session, GroupCall call) => runApp(
  MaterialApp(
    theme: mangaTheme(),
    debugShowCheckedModeBanner: false,
    home: CallPage(session: session, call: call),
  ),
);

Future<void> _connected(Session session, GroupCall call, String peer) async {
  _show(session, call);
  try {
    await _until(
      'video from peer',
      () async => await _framesFrom(call, peer) > 10,
    );
  } catch (_) {
    _log('stats ${await call.stats()}');
    rethrow;
  }
  final cryptors = (await call.stats())['cryptors'];
  if (cryptors is! Map || !cryptors.values.contains('FrameCryptorStateOk')) {
    throw StateError('no cryptor reported Ok: $cryptors');
  }
}

/// Creates the group, calls, shares a screen, then sends under a key Bob
/// does not have.
Future<void> _alice() async {
  final peer = _params['peer']!;
  final session = await _session();
  GroupInfo? group;
  await _until('bob key package', () async {
    try {
      group = await session.groups!.create('call', [peer]);
      return true;
    } on MissingKeyPackage {
      return false;
    }
  });
  _log('group created');
  final call = await session.calls!.join(group!.id);
  await _connected(session, call, peer);
  _log('video from bob');

  await Future<void>.delayed(const Duration(seconds: 3));
  await call.shareScreen(
    await navigator.mediaDevices.getUserMedia({'video': true}),
  );
  _log('sharing');
  await Future<void>.delayed(const Duration(seconds: 5));
  await call.stopSharing();

  await Future<void>.delayed(const Duration(seconds: 3));
  final random = Random.secure();
  await call.crypto.setKey(
    Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
    7,
  );
  _log('switched to a foreign key');
  await Future<void>.delayed(const Duration(seconds: 10));
  await session.calls!.leave();
  await session.close();
}

/// Joins, checks video keeps flowing through the screen share, and that it
/// stops once Alice encrypts with a key outside the group.
Future<void> _bob() async {
  final peer = _params['peer']!;
  final session = await _session();
  final groups = session.groups!;
  await _until('invite', () => groups.invites.isNotEmpty);
  await groups.accept(groups.invites.single.id);
  final groupId = groups.spaces.single.id;
  await _until(
    'call running',
    () => session.calls!.inCall(groupId).contains(peer),
  );
  final call = await session.calls!.join(groupId);
  await _connected(session, call, peer);
  _log('video from alice');

  var last = await _framesFrom(call, peer);
  var still = DateTime.now();
  var flowed = 0;
  await _until('video freezes', () async {
    final now = await _framesFrom(call, peer);
    if (now > last) {
      flowed += now - last;
      last = now;
      still = DateTime.now();
    }
    return DateTime.now().difference(still) > const Duration(seconds: 3);
  }, timeout: const Duration(seconds: 40));
  if (flowed < 100) throw StateError('video stalled early: $flowed frames');
  _log('video froze after $flowed more frames');

  await _until(
    'alice leaves',
    () => !call.participants.containsKey(peer),
    timeout: const Duration(seconds: 30),
  );
  await session.calls!.leave();
  await session.close();
}
