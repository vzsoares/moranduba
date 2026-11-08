import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_signal.dart';
import 'receiver_e2ee.dart';
import 'transport.dart';

/// Every participant connects to every other. For each pair the lower pubkey
/// dials, so two offers never cross.
class MeshTransport implements CallTransport {
  MeshTransport(this._host, {this.iceServers = defaultIceServers});

  final CallHost _host;
  final List<Map<String, String>> iceServers;
  final Map<String, RTCPeerConnection> _links = {};

  /// Senders that already have a frame encryptor; one per sender.
  final Set<String> _encrypted = {};
  final Set<String> _dialing = {};
  bool _closed = false;

  @override
  String get mode => 'mesh';

  @override
  String? get sfu => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> participantSeen(String participant) async {
    if (_closed || participant == _host.me) return;
    if (_links.containsKey(participant) || _dialing.contains(participant)) {
      return;
    }
    if (_host.me.compareTo(participant) < 0) await _dial(participant);
  }

  @override
  Future<void> participantMedia(String participant, MediaState media) async {}

  @override
  Future<void> onSignal(String from, CallSignal signal) async {
    if (_closed || signal.to != _host.me) return;
    final sdp = signal.sdp;
    if (sdp == null) return;
    switch (signal.type) {
      case SignalType.offer:
        await _close(from);
        final pc = await _link(from);
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        await pc.setLocalDescription(await pc.createAnswer());
        final answer = await gatheredDescription(pc);
        if (answer?.sdp case final sdp?) {
          await _host.signal(
            CallSignal(
              type: SignalType.answer,
              callId: _host.callId,
              to: from,
              sdp: sdp,
            ),
          );
        }
      case SignalType.answer:
        await _links[from]?.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
      default:
        break;
    }
  }

  Future<void> _dial(String participant) async {
    _dialing.add(participant);
    try {
      final pc = await _link(participant);
      await pc.setLocalDescription(await pc.createOffer());
      final offer = await gatheredDescription(pc);
      if (offer?.sdp case final sdp?) {
        await _host.signal(
          CallSignal(
            type: SignalType.offer,
            callId: _host.callId,
            to: participant,
            sdp: sdp,
          ),
        );
      }
    } finally {
      _dialing.remove(participant);
    }
  }

  Future<RTCPeerConnection> _link(String participant) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _links[participant] = pc;
    final stream = _host.outgoingStream;
    for (final track in _host.outgoingTracks) {
      final sender = stream == null
          ? await pc.addTrack(track)
          : await pc.addTrack(track, stream);
      _encrypted.add(sender.senderId);
      await _host.crypto.encrypt(sender, _host.me);
    }
    if (!_host.outgoingTracks.any((t) => t.kind == 'video')) {
      // Keeps a video slot so a later camera or screen needs no renegotiation.
      final (video, encrypted) = await addEncryptedVideo(
        pc,
        _host,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      if (encrypted) _encrypted.add(video.sender.senderId);
    }
    for (final transceiver in await pc.getTransceivers()) {
      await _host.crypto.decrypt(transceiver.receiver, participant);
    }
    pc.onTrack = (event) {
      // Receivers created by the remote offer; on web the page hook already
      // attached them, since this callback runs too late there.
      final receiver = event.receiver;
      if (receiver != null && !receiversHandledByPage) {
        unawaited(_host.crypto.decrypt(receiver, participant));
      }
      if (event.streams.firstOrNull case final stream?) {
        _host.remoteStream(participant, stream);
      }
    };
    pc.onConnectionState = (state) {
      _host.peerState(participant, state.name);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_redial(participant));
      }
    };
    return pc;
  }

  Future<void> _redial(String participant) async {
    await _close(participant);
    if (_host.me.compareTo(participant) < 0) await _dial(participant);
  }

  @override
  Future<void> participantLeft(String participant) async {
    await _close(participant);
    _host.peerGone(participant);
  }

  Future<void> _close(String participant) async {
    final pc = _links.remove(participant);
    if (pc == null) return;
    try {
      await pc.close();
    } catch (e) {
      debugPrint('close link $participant: $e');
    }
  }

  @override
  Future<void> replaceAudio(MediaStreamTrack track) async {
    for (final pc in [..._links.values]) {
      for (final transceiver in await pc.getTransceivers()) {
        final sender = transceiver.sender;
        if (sender.track?.kind == 'audio') {
          await replaceTrackSettled(sender, track);
        }
      }
    }
  }

  @override
  Future<void> replaceVideo(MediaStreamTrack? track) async {
    for (final pc in [..._links.values]) {
      for (final transceiver in await pc.getTransceivers()) {
        final sender = transceiver.sender;
        final kind = sender.track?.kind ?? transceiver.receiver.track?.kind;
        if (kind != 'video') continue;
        await replaceTrackSettled(sender, track);
        if (track != null && _encrypted.add(sender.senderId)) {
          await _host.crypto.encrypt(sender, _host.me);
        }
      }
    }
  }

  @override
  Future<Map<String, LinkStats>> stats() async => {
    // Links can close while stats are awaited.
    for (final MapEntry(:key, :value) in Map.of(_links).entries)
      key: await linkStats(value),
  };

  @override
  Future<void> close() async {
    _closed = true;
    for (final participant in [..._links.keys]) {
      await _close(participant);
    }
  }
}
