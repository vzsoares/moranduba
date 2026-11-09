// Browser end-to-end check of the member relay (ADR 0003), with three
// pages: ROLES=alice,bob,carol ./e2e/run.sh e2e/relay_e2e.dart
// Alice and Bob strip every ICE candidate from their direct link, so it
// fails and Carol has to relay their media. Then they let candidates
// through again, and the direct link takes over without a gap.
// Each page logs "E2E <role> PASS" or "E2E <role> FAIL …".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:moranduba/core/calls/call_quality.dart';
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

/// Pubkeys of the other roles, in run.ts order (alice, bob, carol).
final _peers = _params['peer']!.split(',');
final _alice = _role == 'alice' ? null : _peers[0];
final _bob = switch (_role) {
  'alice' => _peers[0],
  'bob' => null,
  _ => _peers[1],
};
final _carol = _role == 'carol' ? null : _peers[1];

/// The other end of the blocked pair.
final _blockedPeer = switch (_role) {
  'alice' => _bob,
  'bob' => _alice,
  _ => null,
};

var _blocked = true;

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

Future<Map<Object?, Object?>> _link(GroupCall call, String peer) async {
  final links = (await call.stats())['links'];
  return switch (links) {
    final Map<Object?, Object?> links => switch (links[peer]) {
      final Map<Object?, Object?> link => link,
      _ => const {},
    },
    _ => const {},
  };
}

Future<int> _frames(GroupCall call, String peer) async =>
    switch (await _link(call, peer)) {
      {'framesDecoded': final int frames} => frames,
      _ => 0,
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _run();
    _log('PASS');
  } catch (e, stack) {
    _log('FAIL $e\n$stack');
  }
}

Future<Session> _session() async {
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

Future<String> _group(Session session) async {
  final groups = session.groups!;
  if (_role == 'alice') {
    GroupInfo? group;
    await _until('key packages', () async {
      try {
        group = await groups.create('relay', _peers);
        return true;
      } on MissingKeyPackage {
        return false;
      }
    });
    _log('group created');
    return group!.id;
  }
  await _until('invite', () => groups.invites.isNotEmpty);
  await groups.accept(groups.invites.single.id);
  return groups.spaces.single.id;
}

Future<void> _run() async {
  final session = await _session();
  final groupId = await _group(session);
  final calls = session.calls!;
  calls.directBlocked = (peer) => _blocked && peer == _blockedPeer;
  if (_role != 'alice') {
    await _until('call running', () => calls.inCall(groupId).contains(_alice));
    if (_role == 'carol') {
      await _until(
        'bob in the call',
        () => calls.inCall(groupId).contains(_bob),
      );
    }
  }
  final call = await calls.join(groupId);
  await call.setCamera(true);
  runApp(
    MaterialApp(
      theme: mangaTheme(),
      debugShowCheckedModeBanner: false,
      home: CallPage(session: session, call: call),
    ),
  );
  if (call.mode != 'mesh') throw StateError('call went ${call.mode}');

  final others = [?_alice, ?_bob, ?_carol];
  for (final peer in others) {
    await _until(
      'video from ${peer.substring(0, 8)}',
      () async => await _frames(call, peer) > 10,
      timeout: const Duration(seconds: 90),
    );
  }
  _log('video from everyone');

  final far = _blockedPeer;
  if (far == null) {
    await _carolStays(call);
  } else {
    await _relayed(call, far);
  }
  await calls.leave();
  await session.close();
}

/// Alice or Bob: the other arrives through Carol, encrypted, then directly.
Future<void> _relayed(GroupCall call, String far) async {
  final link = await _link(call, far);
  if (link['via'] != _carol) {
    throw StateError(
      'video from the far end did not come through carol: $link',
    );
  }
  final cryptors = (await call.stats())['cryptors'];
  if (cryptors is! Map || !cryptors.values.contains('FrameCryptorStateOk')) {
    throw StateError('no cryptor reported Ok: $cryptors');
  }
  await _until('relayed link quality', () async {
    final quality = (await call.quality())[far];
    if (quality == null || quality.level == QualityLevel.unknown) return false;
    _log(
      'relayed quality ${quality.level.name}: delay '
      '${quality.roundTrip?.inMilliseconds} ms, loss ${quality.loss}',
    );
    return true;
  });
  _log('relayed through carol');

  // Nothing but the relay ever carried media between the two of us.
  _blocked = false;
  var last = await _frames(call, far);
  var lastFrame = DateTime.now();
  var gap = Duration.zero;
  await _until('direct link back', () async {
    final now = await _frames(call, far);
    if (now != last) {
      last = now;
      final since = DateTime.now().difference(lastFrame);
      if (since > gap) gap = since;
      lastFrame = DateTime.now();
    }
    final link = await _link(call, far);
    return link['via'] == null &&
        '${link['state']}'.toLowerCase() == 'connected';
  }, timeout: const Duration(seconds: 120));
  await _until(
    'video over the direct link',
    () async => await _frames(call, far) > 10,
  );
  if (gap > const Duration(seconds: 8)) {
    throw StateError('video stopped for ${gap.inSeconds} s while switching');
  }
  _log('direct again, longest gap ${gap.inMilliseconds} ms');
  await Future<void>.delayed(const Duration(seconds: 5));
}

/// Carol: stays until both have left.
Future<void> _carolStays(GroupCall call) async {
  await _until(
    'alice and bob leave',
    () => call.participants.isEmpty,
    timeout: const Duration(seconds: 180),
  );
}
