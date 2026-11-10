import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:moranduba/core/calls/call_signal.dart';
import 'package:moranduba/core/calls/mesh_transport.dart';
import 'package:moranduba/core/calls/relay_plan.dart';
import 'package:moranduba/core/calls/sfu_client.dart';
import 'package:moranduba/core/calls/sfu_transport.dart';

import 'support/fake_webrtc.dart';

const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _ok = FrameCryptorState.FrameCryptorStateOk;

/// Runs [body] on fake time, with the host and mesh it builds for [me].
void _onFakeTime(
  String me,
  void Function(FakeAsync time, FakeHost host, MeshTransport mesh) body, {
  bool cloneForwarded = false,
}) {
  fakeAsync((time) {
    late FakeHost host;
    FakeHost.create(me).then((h) => host = h);
    time.flushMicrotasks();
    final mesh = MeshTransport(
      host,
      connect: host.connect,
      cloneForwarded: cloneForwarded,
    );
    body(time, host, mesh);
    mesh.close();
    time.flushMicrotasks();
    expect(host.crypto.cryptorCount, 0, reason: 'call over, cryptors left');
    expect(host.crypto.linkCount, 0);
    expect(host.factory.live, isEmpty);
    host.crypto.dispose();
    time.flushMicrotasks();
    expect(host.factory.live, isEmpty);
    expect(
      host.factory.disposedOpen,
      isEmpty,
      reason: 'a cryptor was disposed while its link was open',
    );
    time.elapse(const Duration(minutes: 5));
  });
}

/// Every live cryptor belongs to an open link and is tracked by the call.
void _consistent(FakeHost host) {
  expect(host.factory.live.length, host.crypto.cryptorCount);
  for (final cryptor in host.factory.live) {
    expect(cryptor.pc.closed, isFalse, reason: '${cryptor.name} outlived');
  }
}

CallSignal _offer(String to, {String? origin}) => CallSignal(
  type: origin == null ? SignalType.offer : SignalType.relayOffer,
  callId: 'call',
  to: to,
  origin: origin,
  sdp: 'remote offer',
);

/// Answers [from]'s offer and brings the link up with its media.
FakePeerConnection _answerUp(
  FakeAsync time,
  FakeHost host,
  MeshTransport m,
  String from,
) {
  m.onSignal(from, _offer(host.me));
  time.flushMicrotasks();
  final pc = host.links.last;
  pc
    ..deliverTracks()
    ..setState(_connected);
  time.flushMicrotasks();
  return pc;
}

Iterable<FakeTrack> get _liveClones => clones.where((t) => !t.stopped);

void main() {
  setUp(clones.clear);
  tearDown(() => cloneGate = null);

  test('relay links that keep failing do not pile up cryptors', () {
    _onFakeTime('c', cloneForwarded: true, (time, host, mesh) {
      _answerUp(time, host, mesh, 'a');
      _answerUp(time, host, mesh, 'b');
      // Two direct links: audio and video out, audio and video in.
      expect(host.crypto.cryptorCount, 8);
      mesh
        ..participantLinks('a', const LinkReport(links: {'c'}, failed: {'b'}))
        ..participantLinks('b', const LinkReport(links: {'c'}, failed: {'a'}));
      time.flushMicrotasks();
      for (var attempt = 0; attempt < 12; attempt++) {
        final relays = host.open.skip(2).toList();
        expect(relays, hasLength(2), reason: 'attempt $attempt');
        expect(host.crypto.cryptorCount, 12, reason: 'attempt $attempt');
        _consistent(host);
        expect(_liveClones, hasLength(4));
        for (final relay in relays) {
          relay.setState(_failed);
        }
        time.flushMicrotasks();
        expect(host.crypto.cryptorCount, 8);
        expect(_liveClones, isEmpty);
        time.elapse(const Duration(seconds: 6));
      }
      expect(host.links.length, greaterThanOrEqualTo(2 + 12 * 2));
    });
  });

  test('a relay stopped while cloning stops the clones it made', () {
    _onFakeTime('c', cloneForwarded: true, (time, host, mesh) {
      _answerUp(time, host, mesh, 'a');
      _answerUp(time, host, mesh, 'b');
      cloneGate = Completer<void>();
      mesh
        ..participantLinks('a', const LinkReport(links: {'c'}, failed: {'b'}))
        ..participantLinks('b', const LinkReport(links: {'c'}, failed: {'a'}));
      time.flushMicrotasks();
      expect(host.open, hasLength(4));
      // Alice and Bob connect directly, so the relays are not needed.
      mesh
        ..participantLinks('a', const LinkReport(links: {'b', 'c'}))
        ..participantLinks('b', const LinkReport(links: {'a', 'c'}));
      time.flushMicrotasks();
      expect(host.open, hasLength(2));
      cloneGate!.complete();
      cloneGate = null;
      time.flushMicrotasks();
      expect(clones, isNotEmpty);
      expect(_liveClones, isEmpty);
      expect(
        host.signals.where((s) => s.type == SignalType.relayOffer),
        isEmpty,
      );
      _consistent(host);
    });
  });

  test('a track id on two links gets a decryptor on each', () {
    _onFakeTime('b', (time, host, mesh) {
      // Native relays forward the received track itself, under its id.
      host.remoteIds = const {'audio': 'a-mic', 'video': 'a-cam'};
      mesh
        ..participantLinks('a', const LinkReport(failed: {'b'}))
        ..participantLinks('c', const LinkReport(links: {'a', 'b'}));
      mesh.onSignal('a', _offer('b'));
      time.flushMicrotasks();
      host.links.last.deliverTracks();
      time.flushMicrotasks();
      // Audio and video out, audio and video in.
      expect(host.crypto.cryptorCount, 4);
      for (var attempt = 0; attempt < 3; attempt++) {
        mesh.onSignal('c', _offer('b', origin: 'a'));
        time.flushMicrotasks();
        host.links.last.deliverTracks();
        time.flushMicrotasks();
        expect(host.crypto.cryptorCount, 6, reason: 'attempt $attempt');
        _consistent(host);
      }
    });
  });

  test('a failed peer is reported again only when its state changes', () {
    _onFakeTime('b', (time, host, mesh) {
      mesh.participantLinks('a', const LinkReport(failed: {'b'}));
      mesh.onSignal('a', _offer('b'));
      time.flushMicrotasks();
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'failed');
      final before = host.stateLog.length;
      for (var i = 1; i <= 5; i++) {
        mesh.participantLinks(
          'd',
          LinkReport(links: {for (var j = 0; j < i; j++) 'e$j'}),
        );
        time.flushMicrotasks();
      }
      expect(host.stateLog.skip(before).where((e) => e.$1 == 'a'), isEmpty);
      mesh.participantLinks('c', const LinkReport(links: {'a', 'b'}));
      time.flushMicrotasks();
      expect(host.stateLog.last, ('a', 'relaying'));
    });
  });

  test('each link keeps its own cryptor state', () {
    fakeAsync((time) {
      late FakeHost host;
      FakeHost.create('me').then((h) => host = h);
      time.flushMicrotasks();
      final mic = FakeTrack('audio', id: 'mic');
      final links = [
        FakePeerConnection(host.factory.log),
        FakePeerConnection(host.factory.log),
      ];
      for (final pc in links) {
        pc.addTrack(mic).then((s) => host.crypto.encrypt(s, 'me', link: pc));
        time.flushMicrotasks();
      }
      final [first, second] = [...host.factory.live];
      first.onFrameCryptorStateChanged?.call('me', _ok);
      expect(host.crypto.allStates, hasLength(2));
      expect(
        host.crypto.allStates.values,
        contains(FrameCryptorState.FrameCryptorStateNew.name),
      );
      second.onFrameCryptorStateChanged?.call('me', _ok);
      expect(host.crypto.allStates.values, everyElement(_ok.name));
      links.first.close();
      host.crypto.release(links.first);
      time.flushMicrotasks();
      first.onFrameCryptorStateChanged?.call(
        'me',
        FrameCryptorState.FrameCryptorStateEncryptionFailed,
      );
      expect(host.crypto.allStates.values, [_ok.name]);
      links.last.close();
      host.crypto.dispose();
      time.flushMicrotasks();
      expect(host.factory.live, isEmpty);
    });
  });

  test('relay offers that fail or repeat release the old link', () {
    _onFakeTime('b', (time, host, mesh) {
      for (var attempt = 0; attempt < 10; attempt++) {
        mesh.onSignal('c', _offer('b', origin: 'a'));
        time.flushMicrotasks();
        expect(host.crypto.cryptorCount, 2, reason: 'attempt $attempt');
        _consistent(host);
        if (attempt.isEven) {
          host.open.single.setState(_failed);
          time.flushMicrotasks();
          expect(host.crypto.cryptorCount, 0);
        }
      }
    });
  });

  test('direct redials keep one link worth of cryptors', () {
    _onFakeTime('a', (time, host, mesh) {
      mesh.participantSeen('b');
      time.flushMicrotasks();
      for (var attempt = 0; attempt < 10; attempt++) {
        final pc = host.open.single;
        pc.deliverTracks();
        time.flushMicrotasks();
        expect(host.crypto.cryptorCount, 4, reason: 'attempt $attempt');
        _consistent(host);
        pc.setState(_failed);
        time.flushMicrotasks();
        expect(host.crypto.cryptorCount, 0);
        time.elapse(redialDelay(attempt + 1) + const Duration(seconds: 1));
      }
      expect(host.links.length, greaterThanOrEqualTo(10));
    });
  });

  test('a link that never connects is dropped with its cryptors', () {
    _onFakeTime('a', (time, host, mesh) {
      mesh.participantSeen('b');
      time.flushMicrotasks();
      for (var attempt = 0; attempt < 5; attempt++) {
        expect(host.crypto.cryptorCount, 4);
        time.elapse(connectTimeout + redialDelay(attempt + 1));
        time.flushMicrotasks();
        _consistent(host);
      }
      expect(host.links.length, greaterThan(4));
    });
  });

  test('a new offer encrypts before the link it replaces closes', () {
    _onFakeTime('b', (time, host, mesh) {
      final old = _answerUp(time, host, mesh, 'a');
      host.factory.log.clear();
      final fresh = _answerUp(time, host, mesh, 'a');
      final log = host.factory.log;
      final created = log.lastIndexOf('create ${fresh.name}');
      final closed = log.indexOf('close ${old.name}');
      final disposed = log.indexOf('dispose ${old.name}');
      expect(created, greaterThanOrEqualTo(0));
      expect(created, lessThan(closed));
      expect(closed, lessThan(disposed));
      expect(host.crypto.cryptorCount, 4);
      _consistent(host);
    });
  });

  test('a track arriving on a closed link gets no cryptor', () {
    _onFakeTime('a', (time, host, mesh) {
      mesh.participantSeen('b');
      time.flushMicrotasks();
      final pc = host.open.single;
      mesh.participantLeft('b');
      time.flushMicrotasks();
      pc.deliverTracks();
      time.flushMicrotasks();
      expect(host.crypto.cryptorCount, 0);
      _consistent(host);
    });
  });

  test('a failed peer shows as relaying until its relay fails', () {
    _onFakeTime('b', (time, host, mesh) {
      mesh
        ..participantLinks('a', const LinkReport(failed: {'b'}))
        ..participantLinks('c', const LinkReport(links: {'a', 'b'}));
      _answerUp(time, host, mesh, 'c');
      mesh.onSignal('a', _offer('b'));
      time.flushMicrotasks();
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'relaying');
      mesh.onSignal('c', _offer('b', origin: 'a'));
      time.flushMicrotasks();
      host.links.last.setState(_connected);
      time.flushMicrotasks();
      expect(host.states['a'], 'relayed');
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'relaying');
      mesh.onSignal('c', _offer('b', origin: 'a'));
      time.flushMicrotasks();
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'failed');
    });
  });

  test('a planned relay that never connects ends in failed', () {
    _onFakeTime('b', (time, host, mesh) {
      mesh
        ..participantLinks('a', const LinkReport(failed: {'b'}))
        ..participantLinks('c', const LinkReport(links: {'a', 'b'}));
      _answerUp(time, host, mesh, 'c');
      mesh.onSignal('a', _offer('b'));
      time.flushMicrotasks();
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'relaying');
      time.elapse(connectTimeout);
      expect(host.states['a'], 'failed');
    });
  });

  test('a failed peer nobody can relay shows as failed at once', () {
    _onFakeTime('b', (time, host, mesh) {
      mesh.participantLinks('a', const LinkReport(failed: {'b'}));
      mesh.onSignal('a', _offer('b'));
      time.flushMicrotasks();
      host.links.last.setState(_failed);
      time.flushMicrotasks();
      expect(host.states['a'], 'failed');
    });
  });

  test('closing an SFU link releases its cryptors after it closes', () {
    fakeAsync((time) {
      late FakeHost host;
      FakeHost.create('me').then((h) => host = h);
      time.flushMicrotasks();
      final sfu = SfuTransport(
        host,
        client: _FakeSfuClient(),
        sfu: 'sfu',
        iceServers: const [],
        connect: host.connect,
      );
      sfu.start();
      time.flushMicrotasks();
      final pc = host.links.single;
      // Audio and video out; the fake adds a receiver to each slot.
      expect(host.crypto.cryptorCount, 2);
      pc.deliverTracks();
      time.flushMicrotasks();
      expect(host.crypto.cryptorCount, 4);
      sfu.close();
      time.flushMicrotasks();
      expect(host.crypto.cryptorCount, 0);
      expect(host.factory.live, isEmpty);
      expect(host.factory.disposedOpen, isEmpty);
      host.crypto.dispose();
      time.elapse(const Duration(minutes: 1));
    });
  });
}

class _FakeSfuClient implements SfuClient {
  @override
  Future<Map<String, Object?>> request(
    String sfu,
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 3),
  }) async => {'sdp': 'sfu answer'};

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}
