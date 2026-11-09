// Browser end-to-end check of encrypted calls. The runner (e2e/run.ts) opens
// one page per participant: ?role=alice|bob&sk=<hex>&peer=<hex pubkey>,
// plus &sfu=<hex pubkey>&code=<claim code> to call through a Moranduba SFU,
// and &switch=1 to move the call to mesh and back mid-call, or &split=1 to
// make the SFU unreachable for Bob so the call has to fall back to mesh. &hostpeer=1
// lists the SFU as a host peer instead of the group's server. &push=1 turns
// on push, so the SFU log shows push_subscribe and ring requests. &late=1
// connects mic-only and turns the camera on afterwards.
// Each page logs "E2E <role> PASS" or "E2E <role> FAIL …".
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;
import 'package:moranduba/core/calls/call_quality.dart';
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
final _late = _params['late'] != null;
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
  if (_late) {
    await _until('audio from peer', () async {
      final links = (await call.stats())['links'];
      return links is Map &&
          switch (links[peer]) {
            {'audioPackets': final int packets} => packets > 50,
            _ => false,
          };
    });
    await call.setCamera(true);
    _log('camera on after connecting');
  }
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
  await _until('link quality', () async {
    final link = (await call.quality())[peer];
    if (link == null || link.level == QualityLevel.unknown) return false;
    _log(
      'quality ${link.level.name}: delay ${link.roundTrip?.inMilliseconds} ms, '
      'loss ${link.loss}, jitter ${link.jitter?.inMilliseconds} ms',
    );
    return link.roundTrip != null && link.loss != null;
  });
  _log('shot quality');
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
  if (!_late) await call.setCamera(true);
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
  if (!_late) await call.setCamera(true);
  await _connected(session, call, peer);
  _log('video from alice');

  // Re-read each time: a mode switch brings a new stream.
  List<MediaStreamTrack> heard() =>
      call.participants[peer]?.stream?.getAudioTracks() ?? [];
  await call.setDeafened(true);
  if (call.micOn || heard().isEmpty || heard().any((t) => t.enabled)) {
    throw StateError('deafen left audio on: mic ${call.micOn}');
  }
  await call.setDeafened(false);
  if (!call.micOn || heard().any((t) => !t.enabled)) {
    throw StateError('undeafen did not restore audio');
  }
  _log('deafen and back');

  final before = call.outgoingTracks.firstWhere((t) => t.kind == 'audio').id;
  await call.applyAudio(call.audio.copyWith(noiseSuppression: false));
  final after = call.outgoingTracks.firstWhere((t) => t.kind == 'audio').id;
  if (before == after) throw StateError('microphone was not reopened');
  _log('audio settings applied');

  call.setMutedForMe(peer, true);
  if (heard().any((t) => t.enabled)) {
    throw StateError('mute for me left audio');
  }
  call.setMutedForMe(peer, false);
  await call.setVolume(peer, .3);
  final id = call.participants[peer]?.renderer?.textureId;
  final element = web.document.getElementById('audio_RTCVideoRenderer-$id');
  final volume = element?.getProperty<JSNumber>('volume'.toJS).toDartDouble;
  if (heard().any((t) => !t.enabled) ||
      volume == null ||
      (volume - .3).abs() > .01) {
    throw StateError('per-person audio not applied: volume $volume');
  }
  _log('per-person mute and volume');

  await call.setVolume(peer, 1.5);
  if (element?.getProperty<JSBoolean>('muted'.toJS).toDart != true) {
    throw StateError('150% did not move playback to WebAudio');
  }
  await call.setVolume(peer, 1);
  final plain = call.outgoingTracks.firstWhere((t) => t.kind == 'audio').id;
  await call.applyAudio(call.audio.copyWith(inputVolume: 1.5));
  final boosted = call.outgoingTracks.firstWhere((t) => t.kind == 'audio').id;
  if (plain == boosted) throw StateError('mic level did not add a gain stage');
  await call.applyAudio(call.audio.copyWith(inputVolume: 1.8));
  _log('levels above 100%');

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
