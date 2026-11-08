import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../groups/group_engine.dart';
import '../groups/groups.dart';
import 'call_log.dart';
import 'call_signal.dart';
import 'group_call.dart';
import 'mesh_transport.dart';
import 'sfu_client.dart';
import 'sfu_transport.dart';
import 'transport.dart';

/// Signals older than this are history replay, not a live call.
const _signalMaxAge = Duration(seconds: 60);
const _presenceTimeout = Duration(seconds: 45);

/// A join older than this no longer rings.
const _ringWindow = Duration(seconds: 30);
const _ringFor = Duration(seconds: 40);

/// A call in another group that wants us in it.
class IncomingCall {
  const IncomingCall({
    required this.groupId,
    required this.callId,
    required this.caller,
  });

  final String groupId;
  final String callId;

  /// Who joined first, as far as we saw.
  final String caller;
}

class _Presence {
  _Presence(this.callId, this.mode, this.sfu);

  final String callId;
  String? mode;
  String? sfu;
  DateTime lastSeen = DateTime.now();
}

/// The first SFU in [candidates] (mode, pubkey) that answers and knows us,
/// with its `pong`. All are pinged at once, so a dead first choice costs
/// one ping timeout, not one per candidate.
Future<({String mode, String sfu, Map<String, Object?> pong})?> pickSfu(
  List<(String, String)> candidates, {
  required Future<Map<String, Object?>> Function(String sfu) ping,
  void Function(String mode, Object problem)? onProblem,
}) async {
  Future<Map<String, Object?>?> probe(String mode, String sfu) async {
    try {
      final pong = await ping(sfu);
      if (pong['allowed'] == true) return pong;
      onProblem?.call(mode, _notAllowed(mode));
    } catch (e) {
      onProblem?.call(mode, e);
    }
    return null;
  }

  final probes = [for (final (mode, sfu) in candidates) probe(mode, sfu)];
  for (final (i, (mode, sfu)) in candidates.indexed) {
    if (await probes[i] case final pong?) {
      return (mode: mode, sfu: sfu, pong: pong);
    }
  }
  return null;
}

SfuException _notAllowed(String mode) => SfuException(
  mode == 'host_peer'
      ? 'The host peer does not know you yet'
      : 'The call server does not know you yet',
);

/// Who is in a call in each group, and the one call we are in.
class Calls extends ChangeNotifier {
  Calls(this._groups, {this.sfuClient}) {
    _subscription = _groups.signals.listen(_onSignal);
  }

  final Groups _groups;
  late final StreamSubscription<GroupSignal> _subscription;
  final Map<String, Map<String, _Presence>> _presence = {};
  GroupCall? active;

  /// Override for tests; otherwise [serverFor] decides.
  CallTransport Function(CallHost host)? transportFactory;

  final SfuClient? sfuClient;

  /// The group's call server pubkey, or null for mesh.
  String? Function(String groupId)? serverFor;

  /// The group's opted-in host peers, in order of preference.
  List<String> Function(String groupId)? hostsFor;

  /// Pings an SFU; tests swap it to make one unreachable.
  late Future<Map<String, Object?>> Function(String sfu) ping = (sfu) =>
      switch (sfuClient) {
        final client? => client.request(sfu, {'type': 'ping'}),
        null => Future.error(const SfuException('Calls have no SFU client')),
      };

  /// Records a call's start and end in the group's chat.
  void Function(String groupId, CallEvent event)? onCallEvent;

  /// Why the last call fell back to mesh, for the UI.
  String? serverProblem;

  /// The call ringing now; only while we are in none.
  IncomingCall? ringing;

  /// We started the active call and nobody has joined yet.
  bool get dialing =>
      _startedActive &&
      (active?.participants.isEmpty ?? false) &&
      !(active?.closed ?? true);
  bool _startedActive = false;

  /// Calls that rang once already, so a later joiner does not ring again.
  final Set<String> _rang = {};
  Timer? _ringTimer;

  /// Stops the ring; the call keeps going without us.
  void decline() {
    if (ringing == null) return;
    _stopRinging();
    notifyListeners();
  }

  void _stopRinging() {
    _ringTimer?.cancel();
    _ringTimer = null;
    ringing = null;
  }

  void _ringIfNew(GroupSignal signal, CallSignal decoded, Duration age) {
    if (active != null || age > _ringWindow) return;
    if (!_rang.add(decoded.callId)) return;
    _ringTimer?.cancel();
    ringing = IncomingCall(
      groupId: signal.groupId,
      callId: decoded.callId,
      caller: signal.sender,
    );
    _ringTimer = Timer(_ringFor, () {
      _stopRinging();
      notifyListeners();
    });
  }

  /// Ends the ring once everyone in that call has left.
  void _stopRingingIfOver(String groupId) {
    final ring = ringing;
    if (ring == null || ring.groupId != groupId) return;
    final cutoff = DateTime.now().subtract(_presenceTimeout);
    final live = (_presence[groupId] ?? const {}).values.any(
      (p) => p.callId == ring.callId && p.lastSeen.isAfter(cutoff),
    );
    if (!live) _stopRinging();
  }

  /// Other members currently in a call in [groupId].
  List<String> inCall(String groupId) {
    final cutoff = DateTime.now().subtract(_presenceTimeout);
    return [
      for (final entry in (_presence[groupId] ?? const {}).entries)
        if (entry.value.lastSeen.isAfter(cutoff)) entry.key,
    ];
  }

  /// Joins the call running in [groupId], or starts one.
  Future<GroupCall> join(String groupId) async {
    _stopRinging();
    final current = active;
    if (current != null && !current.closed) {
      if (current.groupId == groupId) return current;
      await leave();
    }
    final cutoff = DateTime.now().subtract(_presenceTimeout);
    final live = (_presence[groupId] ?? const {}).values
        .where((p) => p.lastSeen.isAfter(cutoff))
        .toList();
    final running = live.firstOrNull;
    final call = await GroupCall.start(
      groups: _groups,
      groupId: groupId,
      callId: running?.callId ?? _newCallId(),
      transport:
          transportFactory ??
          await _chooseTransport(
            groupId,
            live.where((p) => p.callId == running?.callId).toList(),
          ),
      resolve: transportFactory == null
          ? (mode, sfu) => transportFor(groupId, mode, sfu)
          : null,
    );
    active = call;
    _startedActive = running == null;
    if (running == null) {
      onCallEvent?.call(groupId, CallEvent.started(call.callId));
    }
    call.addListener(notifyListeners);
    notifyListeners();
    return call;
  }

  /// A running call keeps the route its participants are on. A new one
  /// takes the group's server, else a host peer, else mesh.
  Future<CallTransport Function(CallHost host)> _chooseTransport(
    String groupId,
    List<_Presence> others,
  ) async {
    serverProblem = null;
    final List<(String, String)> candidates;
    if (others.isNotEmpty) {
      final theirs = [
        for (final p in others)
          if ((p.mode, p.sfu ?? serverFor?.call(groupId))
              case (final String mode, final String sfu) when mode != 'mesh')
            (mode, sfu),
      ].firstOrNull;
      candidates = [?theirs];
    } else {
      final server = serverFor?.call(groupId);
      candidates = [
        if (server != null) ('server', server),
        for (final host in hostsFor?.call(groupId) ?? const <String>[])
          if (host != server) ('host_peer', host),
      ];
    }
    if (candidates.isEmpty) return MeshTransport.new;
    try {
      return await _through(candidates);
    } catch (e) {
      serverProblem = '$e';
      debugPrint('call server: $e');
      return MeshTransport.new;
    }
  }

  /// A transport for [mode] in [groupId], through [sfu] when given, else
  /// through the group's server or first answering host peer. Throws when
  /// none answers and knows us.
  Future<CallTransport Function(CallHost host)> transportFor(
    String groupId,
    String mode, [
    String? sfu,
  ]) async {
    if (mode == 'mesh') return MeshTransport.new;
    final candidates = switch ((mode, sfu)) {
      (_, final String sfu) => [(mode, sfu)],
      ('server', null) => [
        if (serverFor?.call(groupId) case final server?) (mode, server),
      ],
      ('host_peer', null) => [
        for (final host in hostsFor?.call(groupId) ?? const <String>[])
          (mode, host),
      ],
      _ => throw SfuException('Unknown call mode $mode'),
    };
    if (candidates.isEmpty) {
      throw SfuException(
        mode == 'host_peer'
            ? 'Nobody hosts calls for this group'
            : 'This group has no call server',
      );
    }
    return _through(candidates);
  }

  Future<CallTransport Function(CallHost host)> _through(
    List<(String, String)> candidates,
  ) async {
    final client = sfuClient;
    if (client == null) throw const SfuException('Calls have no SFU client');
    Object? problem;
    final picked = await pickSfu(
      candidates,
      ping: ping,
      onProblem: (_, e) => problem ??= e,
    );
    if (picked == null) throw problem ?? const SfuException('No SFU answered');
    final iceServers = iceServersFrom(picked.pong);
    return (CallHost host) => SfuTransport(
      host,
      client: client,
      sfu: picked.sfu,
      iceServers: iceServers,
      mode: picked.mode,
    );
  }

  Future<void> leave() async {
    final call = active;
    active = null;
    if (call != null && !call.closed) {
      final alone = call.participants.isEmpty && inCall(call.groupId).isEmpty;
      if (alone) {
        onCallEvent?.call(
          call.groupId,
          CallEvent.ended(call.callId, seconds: _length(call)),
        );
      }
    }
    // Listeners hear about it even if tearing the call down fails.
    notifyListeners();
    await call?.leave();
  }

  /// From the call's logged start when we have it, else from our joining.
  int _length(GroupCall call) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final started = _groups
        .messagesIn(call.groupId)
        .where((m) => m.call)
        .where((m) {
          final event = CallEvent.decode(m.text);
          return event != null && !event.ended && event.callId == call.callId;
        })
        .map((m) => m.createdAt)
        .firstOrNull;
    return now - (started ?? call.joinedAt);
  }

  void _onSignal(GroupSignal signal) {
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(signal.createdAt * 1000),
    );
    if (age > _signalMaxAge) return;
    final decoded = CallSignal.decode(signal.payload);
    if (decoded == null) return;

    final group = _presence.putIfAbsent(signal.groupId, () => {});
    switch (decoded.type) {
      case SignalType.join || SignalType.here:
        group[signal.sender] = _Presence(
          decoded.callId,
          decoded.mode,
          decoded.sfu,
        );
        if (decoded.type == SignalType.join) {
          _ringIfNew(signal, decoded, age);
        }
      case SignalType.leave:
        group.remove(signal.sender);
        _stopRingingIfOver(signal.groupId);
      case SignalType.switchMode:
        for (final p in group.values) {
          if (p.callId != decoded.callId) continue;
          p
            ..mode = decoded.mode
            ..sfu = decoded.sfu;
        }
      default:
        break;
    }

    final call = active;
    if (call != null &&
        call.groupId == signal.groupId &&
        call.callId == decoded.callId) {
      unawaited(
        call
            .handle(signal.sender, decoded)
            .catchError((Object e) => debugPrint('call signal: $e')),
      );
    }
    notifyListeners();
  }

  Future<void> close() async {
    _stopRinging();
    await _subscription.cancel();
    await leave();
  }
}

String _newCallId() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 8; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
