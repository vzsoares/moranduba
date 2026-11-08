// Browser end-to-end check of encrypted calls. The runner (e2e/run.ts) opens
// one page per participant: ?role=alice|bob&sk=<hex>&peer=<hex pubkey>,
// plus &sfu=<hex pubkey>&code=<claim code> to call through a Moranduba SFU,
// and &switch=1 to move the call to mesh and back mid-call, or &split=1 to
// make the SFU unreachable for Bob so the call has to fall back to mesh. &hostpeer=1
// lists the SFU as a host peer instead of the group's server. &push=1 turns
// on push, so the SFU log shows push_subscribe and ring requests.
// Each page logs "E2E <role> PASS" or "E2E <role> FAIL …".
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:moranduba/core/calls/group_call.dart';
import 'package:moranduba/core/calls/sfu_client.dart';
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
final _sfu = _params['sfu'];
final _split = _params['split'] != null;
final _hostPeer = _params['hostpeer'] != null;
final _sfuMode = _hostPeer ? 'host_peer' : 'server';
final _mode = _sfu == null || (_split && _role == 'bob') ? 'mesh' : _sfuMode;

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

Future<Session> _session() async {
  final id = Identity.fromPrivateKey(_params['sk']!);
  final session = await Session.start(
    id,
    relays: _relays,
    openGroupEngine: () => RustGroupEngine.open(
      bridge: createMlsBridge(),
      secretKey: id.privateKey,
      storageKey: '22' * 32,
      store: MemorySnapshotStore(),
    ),
  );
  if (_params['push'] != null) session.enablePush();
  return session;
}

/// The real call page; Chrome decodes remote video only while it renders.
void _show(Session session, GroupCall call) => runApp(
  MaterialApp(
    theme: mangaTheme(),
    debugShowCheckedModeBanner: false,
    home: CallPage(session: session, call: call),
  ),
);

/// Waits until the call server lets us in, so the call does not fall back
/// to mesh.
Future<void> _serverReady(Session session) async {
  final sfu = _sfu;
  if (sfu == null) return;
  await _until('server allows us', () async {
    try {
      return (await session.pingServer(sfu))['allowed'] == true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> _connected(Session session, GroupCall call, String peer) async {
  if (call.mode != _mode) {
    throw StateError('call went ${call.mode}, wanted $_mode');
  }
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
  if (_sfu case final sfu?) {
    if (_params['code'] case final code?) await session.claimServer(sfu, code);
    if (_hostPeer) {
      await session.setHost(group!.id, sfu, on: true);
    } else {
      await session.setServer(group!.id, sfu);
    }
    await _serverReady(session);
    _log('server set');
  }
  final call = await session.calls!.join(group!.id);
  if (!session.calls!.dialing) throw StateError('not dialing a new call');
  await call.setCamera(true);
  await _connected(session, call, peer);
  if (session.calls!.dialing) throw StateError('still dialing with bob in');
  _log('video from bob');
  if (_split) {
    if (call.mode != 'mesh') throw StateError('split call stayed ${call.mode}');
    _log('fell back to mesh');
  }

  if (_params['switch'] != null) {
    for (final mode in ['mesh', _sfuMode]) {
      await call.switchMode(mode);
      if (call.mode != mode) {
        throw StateError('switch to $mode failed: ${call.switchProblem}');
      }
      await _until(
        'video over $mode',
        () async => await _framesFrom(call, peer) > 10,
      );
      _log('switched to $mode');
    }
  }

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
  if (_sfu case final sfu?) {
    await _until(
      'server choice',
      () => _hostPeer
          ? session.hostsOf(groupId).contains(sfu)
          : session.serverOf(groupId) == sfu,
    );
    if (_split) {
      session.calls!.ping = (_) =>
          Future.error(const SfuException('unreachable in this test'));
    } else {
      await _serverReady(session);
    }
  }
  await _until(
    'call running',
    () => session.calls!.inCall(groupId).contains(peer),
  );
  final ringing = session.calls!.ringing;
  if (ringing?.groupId != groupId || ringing?.caller != peer) {
    throw StateError('no ring for the call: $ringing');
  }
  _log('ringing');
  final call = await session.calls!.join(groupId);
  if (session.calls!.ringing != null) throw StateError('still ringing');
  await call.setCamera(true);
  await _connected(session, call, peer);
  _log('video from alice');

  await call.setDeafened(true);
  final heard = call.participants[peer]?.stream?.getAudioTracks() ?? [];
  if (call.micOn || heard.isEmpty || heard.any((t) => t.enabled)) {
    throw StateError('deafen left audio on: mic ${call.micOn}');
  }
  await call.setDeafened(false);
  if (!call.micOn || heard.any((t) => !t.enabled)) {
    throw StateError('undeafen did not restore audio');
  }
  _log('deafen and back');

  var last = await _framesFrom(call, peer);
  var still = DateTime.now();
  var flowed = 0;
  await _until('video freezes', () async {
    final now = await _framesFrom(call, peer);
    // A mode switch starts a new link, whose counter starts over.
    if (now != last) {
      flowed += now > last ? now - last : now;
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
