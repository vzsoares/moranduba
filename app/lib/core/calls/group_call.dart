import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../groups/groups.dart';
import 'audio_prefs.dart';
import 'call_crypto.dart';
import 'call_quality.dart';
import 'call_signal.dart';
import 'mesh_transport.dart';
import 'screen_capture.dart';
import 'transport.dart';
import 'volume.dart';

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

  /// Our own choices about them; nobody else sees these.
  bool mutedForMe = false;
  double volume = 1;
  bool videoHidden = false;
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
    this.audio,
  );

  static Future<GroupCall> start({
    required Groups groups,
    required String groupId,
    required String callId,
    CallTransport Function(CallHost host)? transport,
    Future<CallTransport Function(CallHost host)> Function(
      String mode,
      String? sfu,
    )?
    resolve,
    AudioPrefs audio = const AudioPrefs(),
  }) async {
    final call = GroupCall._(
      groups,
      groupId,
      callId,
      await CallCrypto.create(),
      resolve,
      audio,
    );
    await call._openMedia();
    await callServiceUpdate(sharing: false);
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
  final _meter = QualityMeter();

  /// Builds transports for mode switches, through the SFU when named;
  /// null when switching is off.
  final Future<CallTransport Function(CallHost host)> Function(
    String mode,
    String? sfu,
  )?
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

  /// Unix seconds.
  final int joinedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final localRenderer = RTCVideoRenderer();

  /// The mic, plus the camera track while the camera is on.
  MediaStream? _local;

  /// The camera's own stream, for the local preview.
  MediaStream? _camera;
  MediaStream? _screen;
  bool micOn = true;

  /// Microphone, speaker and voice processing in use.
  AudioPrefs audio;

  /// Everyone silenced for us, our mic with it.
  bool deafened = false;
  bool _micBeforeDeafen = true;
  bool cameraOn = false;
  bool videoCapped = false;

  bool get sharing => _screen != null;
  String get mode => _transport.mode;

  /// The SFU carrying the call (hex pubkey); null in mesh.
  String? get sfu => _transport.sfu;

  /// The group epoch whose exported key encrypts the frames; -1 before
  /// the first.
  int get keyEpoch => _keyEpoch;

  @override
  String get me => _groups.me;

  @override
  MediaStream? get outgoingStream => _local;

  @override
  List<MediaStreamTrack> get outgoingTracks => [
    ...?_local?.getAudioTracks(),
    if (_screen?.getVideoTracks().firstOrNull case final screen?)
      screen
    else if (cameraOn)
      ...?_local?.getVideoTracks(),
  ];

  MediaState get localMedia =>
      MediaState(audio: micOn, video: cameraOn, screen: sharing);

  /// Calls start with the mic only; the camera is asked for on first use.
  Future<void> _openMedia() async {
    await localRenderer.initialize();
    _local = await _leveled(await _microphone(audio));
  }

  /// The mic through a gain stage when its level is not 100% and the
  /// platform has one.
  MicLevel? _micLevel;

  Future<MediaStream> _leveled(MediaStream raw) async {
    final previous = _micLevel;
    _micLevel = audio.inputVolume == 1
        ? null
        : await levelMic(raw, audio.inputVolume);
    await previous?.dispose();
    return _micLevel?.stream ?? raw;
  }

  /// The microphone [prefs] ask for, or the default one when that device
  /// is gone.
  static Future<MediaStream> _microphone(AudioPrefs prefs) async {
    try {
      return await navigator.mediaDevices.getUserMedia({
        'audio': prefs.constraints(),
      });
    } catch (e) {
      if (prefs.input == null) rethrow;
      debugPrint('microphone ${prefs.input}: $e');
      return navigator.mediaDevices.getUserMedia({
        'audio': prefs.copyWith(input: () => null).constraints(),
      });
    }
  }

  Future<void> _audioChanges = Future.value();

  /// Switches microphone, speaker, levels and voice processing mid-call,
  /// one change at a time: a slider drag sends many.
  Future<void> applyAudio(AudioPrefs prefs) =>
      _audioChanges = _audioChanges.then((_) => _applyPrefs(prefs));

  Future<void> _applyPrefs(AudioPrefs prefs) async {
    final local = _local;
    if (_closed || local == null) return;
    final previous = audio;
    audio = prefs;
    if (prefs.output != previous.output) _applyOutput();
    if (prefs.outputVolume != previous.outputVolume) {
      for (final p in participants.values) {
        await setPlaybackVolume(p.renderer, p.stream, _volumeOf(p));
      }
    }
    final sameInput =
        prefs.input == previous.input &&
        prefs.echoCancellation == previous.echoCancellation &&
        prefs.noiseSuppression == previous.noiseSuppression &&
        prefs.autoGain == previous.autoGain;
    final level = _micLevel;
    // Only the level moved and a gain stage is in place: turn it.
    if (sameInput && level != null && prefs.inputVolume != 1) {
      level.gain = prefs.inputVolume;
      return;
    }
    if (sameInput && prefs.inputVolume == previous.inputVolume) return;
    final fresh = await _leveled(await _microphone(prefs));
    final track = fresh.getAudioTracks().firstOrNull;
    if (track == null) return;
    track.enabled = micOn;
    await _transport.replaceAudio(track);
    for (final old in local.getAudioTracks()) {
      await local.removeTrack(old);
      await old.stop();
    }
    await local.addTrack(track);
    _notify();
  }

  /// Plays everyone through the chosen speaker.
  void _applyOutput() {
    final output = audio.output;
    if (output == null) return;
    for (final p in participants.values) {
      unawaited(p.renderer?.audioOutput(output));
    }
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
        _fallBackIfSplit(signal.mode, signal.sfu);
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
        await _applyMode(mode, signal.sfu);
    }
    _notify();
  }

  bool get canSwitch => _resolve != null;

  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);

  /// Someone could not reach our SFU and called on mesh, or reached a
  /// different one; mesh works for everyone, so the whole call moves there.
  /// Heartbeats sent just before a switch still carry the old mode, hence
  /// the grace period.
  void _fallBackIfSplit(String? theirMode, String? theirSfu) {
    final mine = _transport.sfu;
    if (theirMode == null || mine == null) return;
    final split = theirMode == 'mesh' || (theirSfu != null && theirSfu != mine);
    if (!split || switching || !canSwitch) return;
    final since = DateTime.now().difference(_lastSwitch);
    if (since < const Duration(seconds: 20)) return;
    unawaited(switchMode('mesh'));
  }

  /// Moves everyone in the call to [mode]. Outside mesh, the switch names
  /// the SFU we reached so everyone uses the same one.
  Future<void> switchMode(String mode) =>
      _applyMode(mode, null, announce: true);

  /// Make before break: the new transport carries media before the old one
  /// closes. Local tracks and keys stay as they are.
  Future<void> _applyMode(
    String mode,
    String? sfu, {
    bool announce = false,
  }) async {
    final resolve = _resolve;
    if (resolve == null || _closed) return;
    if (mode == _transport.mode && (sfu == null || sfu == _transport.sfu)) {
      return;
    }
    _lastSwitch = DateTime.now();
    switching = true;
    switchProblem = null;
    _notify();
    try {
      final next = (await resolve(mode, sfu))(this);
      if (announce) {
        _switchSeq += 1;
        _switchFrom = me;
        await signal(
          CallSignal(
            type: SignalType.switchMode,
            callId: callId,
            mode: mode,
            sfu: next.sfu,
            seq: _switchSeq,
            media: localMedia,
          ),
        );
      }
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

  Future<void> _announce(SignalType type) => signal(
    CallSignal(
      type: type,
      callId: callId,
      media: localMedia,
      mode: _transport.mode,
      sfu: _transport.sfu,
    ),
  );

  @override
  void remoteStream(String participant, MediaStream stream) {
    final p = participants.putIfAbsent(
      participant,
      () => CallParticipant(participant),
    );
    if (p.stream?.id == stream.id) return;
    p.stream = stream;
    _applyAudio();
    final renderer = p.renderer;
    if (renderer == null) {
      final created = RTCVideoRenderer();
      p.renderer = created;
      unawaited(
        created.initialize().then((_) async {
          created.srcObject = stream;
          if (audio.output case final output?) {
            await created.audioOutput(output);
          }
          if (_volumeOf(p) != 1) {
            await setPlaybackVolume(created, stream, _volumeOf(p));
          }
          _notify();
        }),
      );
    } else {
      renderer.srcObject = stream;
      if (_volumeOf(p) != 1) {
        unawaited(setPlaybackVolume(renderer, stream, _volumeOf(p)));
      }
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
    releasePlayback(p?.renderer);
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

  /// Deafening mutes the mic too; undeafening brings it back as it was.
  Future<void> setDeafened(bool on) async {
    if (on == deafened) return;
    deafened = on;
    _applyAudio();
    if (on) {
      _micBeforeDeafen = micOn;
      if (micOn) return setMic(false);
    } else if (_micBeforeDeafen) {
      return setMic(true);
    }
    _notify();
  }

  /// Plays each participant's audio unless we are deafened or muted them.
  void _applyAudio() {
    for (final p in participants.values) {
      for (final track in p.stream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
        track.enabled = !deafened && !p.mutedForMe;
      }
    }
  }

  /// Silences [pubkey] for us only.
  void setMutedForMe(String pubkey, bool muted) {
    final p = participants[pubkey];
    if (p == null) return;
    p.mutedForMe = muted;
    _applyAudio();
    _notify();
  }

  /// How loud [pubkey] plays for us, 0 to 2, before the overall level.
  Future<void> setVolume(String pubkey, double volume) async {
    final p = participants[pubkey];
    if (p == null) return;
    p.volume = volume;
    _notify();
    await setPlaybackVolume(p.renderer, p.stream, _volumeOf(p));
  }

  double _volumeOf(CallParticipant p) => p.volume * audio.outputVolume;

  /// Stops showing [pubkey]'s camera or screen to us.
  void setVideoHidden(String pubkey, bool hidden) {
    final p = participants[pubkey];
    if (p == null) return;
    p.videoHidden = hidden;
    _notify();
  }

  /// Unmuting while deafened undeafens too.
  Future<void> setMic(bool on) async {
    if (on && deafened) {
      deafened = false;
      _applyAudio();
    }
    micOn = on;
    for (final track in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = on;
    }
    await _announce(SignalType.here);
    _notify();
  }

  /// Opens the camera when turned on (the browser asks then) and releases
  /// it when turned off. Throws when the camera is denied or missing.
  Future<void> setCamera(bool on) async {
    final local = _local;
    if (on == cameraOn || local == null) return;
    MediaStreamTrack? track;
    if (on) {
      final camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'width': {'ideal': 640},
          'height': {'ideal': 480},
        },
      });
      track = camera.getVideoTracks().firstOrNull;
      if (track == null) {
        await camera.dispose();
        throw StateError('No camera found');
      }
      _camera = camera;
      await local.addTrack(track);
    } else {
      final camera = _camera;
      _camera = null;
      for (final video in local.getVideoTracks()) {
        await local.removeTrack(video);
      }
      for (final video in camera?.getTracks() ?? <MediaStreamTrack>[]) {
        await video.stop();
      }
      await camera?.dispose();
    }
    cameraOn = on;
    if (!sharing) {
      localRenderer.srcObject = _camera;
      await _transport.replaceVideo(track);
    }
    await callServiceUpdate(sharing: sharing);
    await _announce(SignalType.here);
    _notify();
  }

  /// Shares a screen (or any [stream], for tests) in place of the camera.
  Future<void> shareScreen([MediaStream? stream]) async {
    final screen = stream ?? await captureScreen();
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
    await callServiceUpdate(sharing: false);
    localRenderer.srcObject = _camera;
    await _transport.replaceVideo(
      cameraOn ? _local?.getVideoTracks().firstOrNull : null,
    );
    await _announce(SignalType.here);
    _notify();
  }

  /// Link and crypto state, for the UI and the end-to-end tests.
  Future<Map<String, Object?>> stats() async => {
    'mode': mode,
    'sfu': ?_transport.sfu,
    'keyIndex': crypto.keyIndex,
    'epoch': _keyEpoch,
    'links': {
      for (final entry in (await _transport.stats()).entries)
        entry.key: entry.value.toJson(),
    },
    'cryptors': crypto.allStates,
  };

  /// Each link's quality since the previous call; poll it on a timer.
  Future<Map<String, LinkQuality>> quality() async =>
      _meter.measure(await _transport.stats());

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
    await callServiceStop();
    for (final stream in [_local, _camera, _screen].nonNulls) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    await _micLevel?.dispose();
    for (final p in participants.values) {
      releasePlayback(p.renderer);
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
