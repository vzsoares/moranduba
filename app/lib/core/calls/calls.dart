import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../groups/group_engine.dart';
import '../groups/groups.dart';
import 'call_signal.dart';
import 'group_call.dart';
import 'mesh_transport.dart';
import 'sfu_client.dart';
import 'sfu_transport.dart';
import 'transport.dart';

/// Signals older than this are history replay, not a live call.
const _signalMaxAge = Duration(seconds: 60);
const _presenceTimeout = Duration(seconds: 45);

class _Presence {
  _Presence(this.callId);

  final String callId;
  DateTime lastSeen = DateTime.now();
}

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

  /// Why the last call fell back to mesh, for the UI.
  String? serverProblem;

  /// Other members currently in a call in [groupId].
  List<String> inCall(String groupId) {
    final cutoff = DateTime.now().subtract(_presenceTimeout);
    return [
      for (final entry in (_presence[groupId] ?? const {}).entries)
        if (entry.value.lastSeen.isAfter(cutoff)) entry.key,
    ];
  }

  /// Joins the call running in [groupId], or starts one.
  Future<GroupCall> join(String groupId, {bool video = true}) async {
    final current = active;
    if (current != null && !current.closed) {
      if (current.groupId == groupId) return current;
      await leave();
    }
    final cutoff = DateTime.now().subtract(_presenceTimeout);
    final running = (_presence[groupId] ?? const {}).values
        .where((p) => p.lastSeen.isAfter(cutoff))
        .map((p) => p.callId)
        .firstOrNull;
    final call = await GroupCall.start(
      groups: _groups,
      groupId: groupId,
      callId: running ?? _newCallId(),
      video: video,
      transport: transportFactory ?? await _chooseTransport(groupId),
    );
    active = call;
    call.addListener(notifyListeners);
    notifyListeners();
    return call;
  }

  /// `server` when the group's SFU answers a ping in time and knows us,
  /// else mesh.
  Future<CallTransport Function(CallHost host)> _chooseTransport(
    String groupId,
  ) async {
    serverProblem = null;
    final sfu = serverFor?.call(groupId);
    final client = sfuClient;
    if (sfu == null || client == null) return MeshTransport.new;
    try {
      final pong = await client.request(sfu, {'type': 'ping'});
      if (pong['allowed'] != true) {
        throw const SfuException('The call server does not know you yet');
      }
      final iceServers = iceServersFrom(pong);
      return (CallHost host) =>
          SfuTransport(host, client: client, sfu: sfu, iceServers: iceServers);
    } catch (e) {
      serverProblem = '$e';
      debugPrint('call server $sfu: $e');
      return MeshTransport.new;
    }
  }

  Future<void> leave() async {
    final call = active;
    active = null;
    await call?.leave();
    notifyListeners();
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
        group[signal.sender] = _Presence(decoded.callId);
      case SignalType.leave:
        group.remove(signal.sender);
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
