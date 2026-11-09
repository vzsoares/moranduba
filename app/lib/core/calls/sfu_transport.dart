import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_signal.dart';
import 'receiver_e2ee.dart';
import 'relay_plan.dart';
import 'sfu_client.dart';
import 'transport.dart';

/// Simulcast layers the SFU picks from per receiver (ADR 0002).
final _layers = [
  RTCRtpEncoding(rid: 'q', scaleResolutionDownBy: 4, maxBitrate: 150000),
  RTCRtpEncoding(rid: 'h', scaleResolutionDownBy: 2, maxBitrate: 500000),
  RTCRtpEncoding(rid: 'f', maxBitrate: 1200000),
];

/// Reads `ice_servers` from a `pong`.
List<Map<String, Object>> iceServersFrom(Map<String, Object?> pong) => [
  if (pong['ice_servers'] case final List<Object?> servers)
    for (final server in servers)
      if (server case {'urls': final Object urls})
        {
          'urls': urls,
          if (server['username'] case final String username)
            'username': username,
          if (server['credential'] case final String credential)
            'credential': credential,
        },
];

/// All media goes through one Moranduba SFU: one peer connection, one
/// DataChannel for the SFU's renegotiation, streams named by publisher.
class SfuTransport implements CallTransport {
  SfuTransport(
    this._host, {
    required this.client,
    required this.sfu,
    required this.iceServers,
    this.mode = 'server',
  });

  final CallHost _host;
  final SfuClient client;

  /// The SFU's pubkey, hex.
  @override
  final String sfu;
  final List<Map<String, Object>> iceServers;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  RTCRtpSender? _video;
  final List<RTCRtpSender> _audio = [];
  bool _videoEncrypted = false;
  final Map<String, MediaStream> _streams = {};
  final Set<String> _pinned = {};
  Future<void> _renegotiation = Future.value();
  bool _closed = false;

  /// Active speakers the SFU reported, loudest first.
  List<String> speakers = const [];

  /// `server`, or `host_peer` when the SFU runs on a member's desktop.
  @override
  final String mode;

  @override
  Future<void> start() async {
    final pc = await createPeerConnection({
      'iceServers': [...iceServers, ...defaultIceServers],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    final channel = await pc.createDataChannel(
      'moranduba',
      RTCDataChannelInit()
        ..negotiated = true
        ..id = 0,
    );
    _channel = channel;
    channel.onMessage = (message) => _onChannel(message.text);

    final stream = _host.outgoingStream;
    final streams = [?stream];
    final audio = _host.outgoingTracks.where((t) => t.kind == 'audio');
    for (final track in audio) {
      final transceiver = await pc.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: streams,
        ),
      );
      await _host.crypto.encrypt(transceiver.sender, _host.me);
      _audio.add(transceiver.sender);
    }
    final camera = _host.outgoingTracks
        .where((t) => t.kind == 'video')
        .firstOrNull;
    final init = RTCRtpTransceiverInit(
      direction: TransceiverDirection.SendRecv,
      streams: streams,
      sendEncodings: _layers,
    );
    // Without a camera the slot still exists, for a later camera or screen.
    final (video, encrypted) = await addEncryptedVideo(
      pc,
      _host,
      init: init,
      track: camera,
    );
    _video = video.sender;
    _videoEncrypted = encrypted;

    pc.onTrack = _onTrack;
    pc.onConnectionState = (state) {
      for (final participant in _streams.keys) {
        _host.peerState(participant, state.name);
      }
    };

    await pc.setLocalDescription(await pc.createOffer());
    final offer = await gatheredDescription(pc);
    final sdp = offer?.sdp;
    if (sdp == null) throw const SfuException('No local offer');
    final answer = await client.request(sfu, {
      'type': 'join',
      'room': _host.callId,
      'sdp': sdp,
    }, timeout: const Duration(seconds: 10));
    final answerSdp = switch (answer['sdp']) {
      final String s => s,
      _ => throw const SfuException('Answer without SDP'),
    };
    await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  }

  void _onTrack(RTCTrackEvent event) {
    final stream = event.streams.firstOrNull;
    if (stream == null) return;
    final participant = stream.id;
    if (participant == _host.me) return;
    // On web the page hook attached the receiver already.
    final receiver = event.receiver;
    if (receiver != null && !receiversHandledByPage) {
      unawaited(_host.crypto.decrypt(receiver, participant));
    }
    _streams[participant] = stream;
    _host.remoteStream(participant, stream);
    _host.peerState(participant, 'connected');
  }

  void _onChannel(String text) {
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    switch (message) {
      case {'type': 'offer', 'sdp': final String sdp}:
        _renegotiation = _renegotiation
            .then((_) => _answer(sdp))
            .catchError((Object e) => debugPrint('sfu renegotiation: $e'));
      case {'type': 'speakers', 'pubkeys': final List<Object?> pubkeys}:
        speakers = pubkeys.whereType<String>().toList();
    }
  }

  Future<void> _answer(String sdp) async {
    final pc = _pc;
    if (pc == null || _closed) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _send({'type': 'answer', 'sdp': answer.sdp});
  }

  void _send(Map<String, Object?> message) {
    final channel = _channel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    unawaited(channel.send(RTCDataChannelMessage(jsonEncode(message))));
  }

  /// Asks for [rid] (`q`, `h` or `f`) of [participant]'s video.
  void preferLayer(String participant, String rid) =>
      _send({'type': 'layer', 'pubkey': participant, 'rid': rid});

  @override
  Future<void> onSignal(String from, CallSignal signal) async {}

  @override
  Future<void> participantSeen(String participant) async {}

  @override
  Future<void> participantMedia(String participant, MediaState media) async {
    final changed = media.screen
        ? _pinned.add(participant)
        : _pinned.remove(participant);
    if (changed) _sendPins();
  }

  void _sendPins() => _send({
    'type': 'pin',
    'pubkeys': [..._pinned],
  });

  @override
  LinkReport? get linkReport => null;

  @override
  Future<void> participantLinks(String participant, LinkReport report) async {}

  @override
  Future<void> participantLeft(String participant) async {
    _streams.remove(participant);
    if (_pinned.remove(participant)) _sendPins();
    _host.peerGone(participant);
  }

  @override
  Future<void> replaceAudio(MediaStreamTrack track) async {
    for (final sender in _audio) {
      await replaceTrackSettled(sender, track);
    }
  }

  @override
  Future<void> replaceVideo(MediaStreamTrack? track) async {
    final sender = _video;
    if (sender == null) return;
    await replaceTrackSettled(sender, track);
    if (track != null && !_videoEncrypted) {
      await _host.crypto.encrypt(sender, _host.me);
      _videoEncrypted = true;
    }
  }

  @override
  Future<Map<String, LinkStats>> stats() async {
    final pc = _pc;
    if (pc == null) return const {};
    final owner = {
      for (final entry in _streams.entries)
        for (final track in entry.value.getTracks()) ?track.id: entry.key,
    };
    final reports = await pc.getStats();
    final tallies = {for (final p in _streams.keys) p: LinkTally()};
    for (final report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final participant = owner[report.values['trackIdentifier']];
      tallies[participant]?.inbound(report.values);
    }
    final state = connectionStateOf(pc);
    final roundTrip = roundTripOf(reports);
    return {
      for (final MapEntry(key: participant, value: tally) in tallies.entries)
        participant: tally.stats(state, roundTrip: roundTrip),
    };
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pc = _pc;
    _pc = null;
    try {
      await _channel?.close();
      await pc?.close();
    } catch (e) {
      debugPrint('close sfu link: $e');
    }
  }
}
