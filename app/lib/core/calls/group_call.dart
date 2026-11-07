import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../groups/groups.dart';
import 'call_crypto.dart';
import 'call_signal.dart';
import 'mesh_transport.dart';
import 'transport.dart';

/// Above this many other participants, mesh stops sending camera video.
const meshVideoCap = 4;

const _heartbeat = Duration(seconds: 15);
const _presenceTimeout = Duration(seconds: 45);

class CallParticipant {
  CallParticipant(this.pubkey);

  final String pubkey;
  MediaState media = const MediaState();
  String state = 'new';
  DateTime lastSeen = DateTime.now();
  MediaStream? stream;
  RTCVideoRenderer? renderer;
}

/// One call in one group: local media, the MLS-derived key, presence, and
/// the transport that carries the media.
class GroupCall extends ChangeNotifier implements CallHost {
  GroupCall._(
    this._groups,
    this.groupId,
    this.callId,
    this.crypto,
    this._resolve,
  );

  static Future<GroupCall> start({
    required Groups groups,
    required String groupId,
    required String callId,
    bool video = true,
    CallTransport Function(CallHost host)? transport,
    Future<CallTransport Function(CallHost host)> Function(String mode)?
    resolve,
  }) async {
    final call = GroupCall._(
      groups,
      groupId,
      callId,
      await CallCrypto.create(),
      resolve,
    );
    await call._openMedia(video: video);
    await call._rekey();
    call._transport = (transport ?? MeshTransport.new)(call);
    try {
      await call._transport.start();
    } catch (e) {
      if (call._transport.mode == 'mesh') rethrow;
      debugPrint('${call._transport.mode} failed, using mesh: $e');
      await call._transport.close();
      call._transport = MeshTransport(call);
      await call._transport.start();
    }
    groups.addListener(call._onGroupChanged);
    call._ticker = Timer.periodic(_heartbeat, (_) => call._tick());
    await call._announce(SignalType.join);
    return call;
  }

  final Groups _groups;
  final String groupId;
  @override
  final String callId;
  @override
  final CallCrypto crypto;
  late CallTransport _transport;

  /// Builds transports for mode switches; null when switching is off.
  final Future<CallTransport Function(CallHost host)> Function(String mode)?
  _resolve;
  int _switchSeq = 0;
  String _switchFrom = '';

  /// Mesh offers that arrived before our own switch to mesh.
  final List<(String, CallSignal)> _earlyOffers = [];
  bool switching = false;

  /// Why the last switch failed, for the UI.
  String? switchProblem;
  Timer? _ticker;
  int _keyEpoch = -1;
  bool _closed = false;

  final Map<String, CallParticipant> participants = {};
  final localRenderer = RTCVideoRenderer();
  MediaStream? _camera;
  MediaStream? _screen;
  bool micOn = true;
  bool cameraOn = false;
  bool videoCapped = false;

  bool get sharing => _screen != null;
  String get mode => _transport.mode;
  bool get hasCamera => _camera?.getVideoTracks().isNotEmpty ?? false;

  @override
  String get me => _groups.me;

  @override
  MediaStream? get outgoingStream => _camera;

  @override
  List<MediaStreamTrack> get outgoingTracks => [
    ...?_camera?.getAudioTracks(),
    if (_screen?.getVideoTracks().firstOrNull case final screen?)
      screen
    else if (cameraOn)
      ...?_camera?.getVideoTracks(),
  ];

  MediaState get localMedia =>
      MediaState(audio: micOn, video: cameraOn, screen: sharing);

  Future<void> _openMedia({required bool video}) async {
    await localRenderer.initialize();
    try {
      _camera = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video
            ? {
                'width': {'ideal': 640},
                'height': {'ideal': 480},
              }
            : false,
      });
    } catch (e) {
      debugPrint('camera unavailable, audio only: $e');
      _camera = await navigator.mediaDevices.getUserMedia({'audio': true});
    }
    cameraOn = hasCamera;
    localRenderer.srcObject = _camera;
  }

  /// Takes the key for the group's current epoch.
  Future<void> _rekey() async {
    final exported = await _groups.callKey(groupId, callId);
    if (exported.epoch == _keyEpoch) return;
    _keyEpoch = exported.epoch;
    await crypto.setKey(exported.secret, exported.epoch);
  }

  void _onGroupChanged() {
    final epoch = _groups.group(groupId)?.epoch;
    if (_closed || epoch == null || epoch == _keyEpoch) return;
    // Give everyone a moment to process the same commit before switching.
    Timer(const Duration(milliseconds: 1500), () {
      if (!_closed) unawaited(_rekey());
    });
  }

  /// Routes a decoded signal from [from] for this call.
  Future<void> handle(String from, CallSignal signal) async {
    if (_closed || from == me) return;
    switch (signal.type) {
      case SignalType.join || SignalType.here:
        final participant = participants.putIfAbsent(
          from,
          () => CallParticipant(from),
        );
        participant
          ..media = signal.media
          ..lastSeen = DateTime.now();
        if (signal.type == SignalType.join) {
          await _announce(SignalType.here);
        }
        _applyVideoCap();
        await _transport.participantSeen(from);
        await _transport.participantMedia(from, signal.media);
      case SignalType.leave:
        await _transport.participantLeft(from);
      case SignalType.offer || SignalType.answer:
        participants.putIfAbsent(from, () => CallParticipant(from)).lastSeen =
            DateTime.now();
        if (_transport.mode != 'mesh' && signal.to == me) {
          _earlyOffers.add((from, signal));
        } else {
          await _transport.onSignal(from, signal);
        }
      case SignalType.switchMode:
        final mode = signal.mode;
        if (mode == null) break;
        final newer =
            signal.seq > _switchSeq ||
            (signal.seq == _switchSeq && from.compareTo(_switchFrom) > 0);
        if (!newer) break;
        _switchSeq = signal.seq;
        _switchFrom = from;
        await _applyMode(mode);
    }
    _notify();
  }

  bool get canSwitch => _resolve != null;

  /// Moves everyone in the call to [mode] (`mesh` or `server`).
  Future<void> switchMode(String mode) async {
    _switchSeq += 1;
    _switchFrom = me;
    await signal(
      CallSignal(
        type: SignalType.switchMode,
        callId: callId,
        mode: mode,
        seq: _switchSeq,
        media: localMedia,
      ),
    );
    await _applyMode(mode);
  }

  /// Make before break: the new transport carries media before the old one
  /// closes. Local tracks and keys stay as they are.
  Future<void> _applyMode(String mode) async {
    final resolve = _resolve;
    if (resolve == null || _closed || mode == _transport.mode) return;
    switching = true;
    switchProblem = null;
    _notify();
    try {
      final next = (await resolve(mode))(this);
      try {
        await next.start();
      } catch (_) {
        await next.close();
        rethrow;
      }
      final old = _transport;
      _transport = next;
      for (final p in [...participants.values]) {
        await next.participantSeen(p.pubkey);
        await next.participantMedia(p.pubkey, p.media);
      }
      final early = [..._earlyOffers];
      _earlyOffers.clear();
      if (next.mode == 'mesh') {
        for (final (from, offer) in early) {
          await next.onSignal(from, offer);
        }
      }
      await old.close();
      _applyVideoCap();
    } catch (e) {
      switchProblem = '$e';
      debugPrint('switch to $mode: $e');
    } finally {
      switching = false;
      _notify();
    }
  }

  @override
  Future<void> signal(CallSignal signal) =>
      _groups.sendSignal(groupId, signal.encode());

  Future<void> _announce(SignalType type) =>
      signal(CallSignal(type: type, callId: callId, media: localMedia));

  @override
  void remoteStream(String participant, MediaStream stream) {
    final p = participants.putIfAbsent(
      participant,
      () => CallParticipant(participant),
    );
    if (p.stream?.id == stream.id) return;
    p.stream = stream;
    final renderer = p.renderer;
    if (renderer == null) {
      final created = RTCVideoRenderer();
      p.renderer = created;
      unawaited(
        created.initialize().then((_) {
          created.srcObject = stream;
          _notify();
        }),
      );
    } else {
      renderer.srcObject = stream;
    }
    _notify();
  }

  @override
  void peerState(String participant, String state) {
    participants[participant]?.state = state
        .replaceFirst('RTCPeerConnectionState', '')
        .toLowerCase();
    _notify();
  }

  @override
  void peerGone(String participant) {
    final p = participants.remove(participant);
    unawaited(p?.renderer?.dispose());
    _notify();
  }

  Future<void> _tick() async {
    if (_closed) return;
    final stale = DateTime.now().subtract(_presenceTimeout);
    for (final p in [...participants.values]) {
      if (p.lastSeen.isBefore(stale)) {
        await _transport.participantLeft(p.pubkey);
      }
    }
    await _announce(SignalType.here);
  }

  void _applyVideoCap() {
    final capped = mode == 'mesh' && participants.length > meshVideoCap;
    if (capped == videoCapped) return;
    videoCapped = capped;
    if (capped && cameraOn && !sharing) unawaited(setCamera(false));
  }

  Future<void> setMic(bool on) async {
    micOn = on;
    for (final track in _camera?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = on;
    }
    await _announce(SignalType.here);
    _notify();
  }

  Future<void> setCamera(bool on) async {
    if (on && !hasCamera) return;
    cameraOn = on;
    if (!sharing) {
      await _transport.replaceVideo(
        on ? _camera?.getVideoTracks().firstOrNull : null,
      );
    }
    await _announce(SignalType.here);
    _notify();
  }

  /// Shares a screen (or any [stream], for tests) in place of the camera.
  Future<void> shareScreen([MediaStream? stream]) async {
    final screen =
        stream ??
        await navigator.mediaDevices.getDisplayMedia({
          'video': true,
          'audio': false,
        });
    final track = screen.getVideoTracks().firstOrNull;
    if (track == null) return;
    _screen = screen;
    track.onEnded = () => unawaited(stopSharing());
    localRenderer.srcObject = screen;
    await _transport.replaceVideo(track);
    await _announce(SignalType.here);
    _notify();
  }

  Future<void> stopSharing() async {
    final screen = _screen;
    if (screen == null) return;
    _screen = null;
    for (final track in screen.getTracks()) {
      await track.stop();
    }
    localRenderer.srcObject = _camera;
    await _transport.replaceVideo(
      cameraOn ? _camera?.getVideoTracks().firstOrNull : null,
    );
    await _announce(SignalType.here);
    _notify();
  }

  /// Link and crypto state, for the UI and the end-to-end tests.
  Future<Map<String, Object?>> stats() async => {
    'mode': mode,
    'keyIndex': crypto.keyIndex,
    'epoch': _keyEpoch,
    'links': {
      for (final entry in (await _transport.stats()).entries)
        entry.key: entry.value.toJson(),
    },
    'cryptors': crypto.allStates,
  };

  Future<void> leave() async {
    if (_closed) return;
    try {
      await _announce(SignalType.leave);
    } catch (e) {
      debugPrint('leave signal: $e');
    }
    _closed = true;
    _ticker?.cancel();
    _groups.removeListener(_onGroupChanged);
    await _transport.close();
    for (final stream in [_camera, _screen].nonNulls) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    for (final p in participants.values) {
      await p.renderer?.dispose();
    }
    await localRenderer.dispose();
    await crypto.dispose();
    notifyListeners();
  }

  bool get closed => _closed;

  void _notify() {
    if (!_closed) notifyListeners();
  }
}
