import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'blank_track.dart';
import 'call_crypto.dart';
import 'call_signal.dart';

/// What a transport needs from the call it carries.
abstract interface class CallHost {
  String get me;
  String get callId;
  CallCrypto get crypto;

  /// Tracks to send: microphone and camera or screen.
  List<MediaStreamTrack> get outgoingTracks;
  MediaStream? get outgoingStream;

  Future<void> signal(CallSignal signal);
  void remoteStream(String participant, MediaStream stream);
  void peerState(String participant, String state);
  void peerGone(String participant);
}

/// Moves media between participants. Switching mode swaps transports and
/// keeps the local tracks and keys.
abstract interface class CallTransport {
  /// `mesh`, `host_peer` or `server`.
  String get mode;

  /// The SFU carrying the call (hex pubkey); null in mesh.
  String? get sfu;

  Future<void> start();

  /// Signals addressed to this transport (offers, answers, presence).
  Future<void> onSignal(String from, CallSignal signal);

  /// A participant appeared (join or presence); mesh may need to dial them.
  Future<void> participantSeen(String participant);

  /// What [participant] sends changed, such as a screen share starting.
  Future<void> participantMedia(String participant, MediaState media);

  Future<void> participantLeft(String participant);

  /// Swaps the outgoing video track (camera, screen or none) on every link.
  Future<void> replaceVideo(MediaStreamTrack? track);

  /// Swaps the outgoing microphone track on every link.
  Future<void> replaceAudio(MediaStreamTrack track);

  /// Per-participant link stats for UI and tests.
  Future<Map<String, LinkStats>> stats();

  Future<void> close();
}

class LinkStats {
  const LinkStats({
    required this.state,
    this.framesDecoded = 0,
    this.audioPackets = 0,
    this.packetsReceived = 0,
    this.packetsLost = 0,
    this.roundTrip,
    this.jitter,
  });

  final String state;
  final int framesDecoded;
  final int audioPackets;

  /// Audio and video, since the link started.
  final int packetsReceived;
  final int packetsLost;

  /// To the peer in mesh, to the SFU otherwise.
  final Duration? roundTrip;

  /// Worst inbound audio jitter.
  final Duration? jitter;

  Map<String, Object> toJson() => {
    'state': state,
    'framesDecoded': framesDecoded,
    'audioPackets': audioPackets,
    'packetsReceived': packetsReceived,
    'packetsLost': packetsLost,
    'roundTripMs': ?roundTrip?.inMilliseconds,
    'jitterMs': ?jitter?.inMilliseconds,
  };
}

/// Sums inbound-rtp reports into one [LinkStats].
class LinkTally {
  int _frames = 0;
  int _audioPackets = 0;
  int _received = 0;
  int _lost = 0;
  double? _jitter;

  void inbound(Map<Object?, Object?> values) {
    final received = _int(values['packetsReceived']);
    _received += received;
    _lost += _int(values['packetsLost']);
    if (values['kind'] == 'video') {
      _frames += _int(values['framesDecoded']);
    } else if (values['kind'] == 'audio') {
      _audioPackets += received;
      if (values['jitter'] case final num jitter
          when jitter > (_jitter ?? -1)) {
        _jitter = jitter.toDouble();
      }
    }
  }

  LinkStats stats(String state, {Duration? roundTrip}) => LinkStats(
    state: state,
    framesDecoded: _frames,
    audioPackets: _audioPackets,
    packetsReceived: _received,
    packetsLost: _lost,
    roundTrip: roundTrip,
    jitter: _seconds(_jitter),
  );
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  _ => 0,
};

Duration? _seconds(Object? value) => switch (value) {
  final num n => Duration(microseconds: (n * 1e6).round()),
  _ => null,
};

/// The round trip of the candidate pair carrying media.
Duration? roundTripOf(List<StatsReport> reports) {
  for (final report in reports) {
    final values = report.values;
    if (report.type == 'candidate-pair' &&
        values['state'] == 'succeeded' &&
        values['nominated'] != false) {
      if (_seconds(values['currentRoundTripTime']) case final rtt?) return rtt;
    }
  }
  return null;
}

String connectionStateOf(RTCPeerConnection pc) =>
    pc.connectionState?.name.replaceFirst('RTCPeerConnectionState', '') ??
    'new';

const defaultIceServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
];

/// Adds a video transceiver sending [track], or nothing yet, encrypted
/// from the start. Chrome skips a sender transform attached after
/// negotiation, so a camera or screen added later would leave in plaintext;
/// dart_webrtc needs a track to attach one, so web borrows a blank track.
/// The bool is false when the sender still needs [CallCrypto.encrypt].
Future<(RTCRtpTransceiver, bool)> addEncryptedVideo(
  RTCPeerConnection pc,
  CallHost host, {
  required RTCRtpTransceiverInit init,
  MediaStreamTrack? track,
}) async {
  final blank = track == null ? await blankVideoTrack() : null;
  final sending = track ?? blank;
  final transceiver = sending == null
      ? await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: init,
        )
      : await pc.addTransceiver(
          track: sending,
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: init,
        );
  if (sending != null) await host.crypto.encrypt(transceiver.sender, host.me);
  if (blank != null) {
    await transceiver.sender.replaceTrack(null);
    await blank.stop();
  }
  return (transceiver, sending != null);
}

/// [addEncryptedVideo] for the answering side: addTrack takes over the remote
/// offer's video slot. Chrome ignores a transform set after replaceTrack on
/// such a slot, so the blank comes in through addTrack. Null on native, where
/// the slot waits for [CallCrypto.encrypt].
Future<RTCRtpSender?> encryptOfferedVideo(
  RTCPeerConnection pc,
  CallHost host,
) async {
  final blank = await blankVideoTrack();
  if (blank == null) return null;
  final stream = host.outgoingStream;
  final sender = stream == null
      ? await pc.addTrack(blank)
      : await pc.addTrack(blank, stream);
  await host.crypto.encrypt(sender, host.me);
  await sender.replaceTrack(null);
  await blank.stop();
  return sender;
}

/// Replaces [sender]'s track and waits until it shows. On web the
/// plugin drops the browser's promise, and a frame cryptor attached before
/// the track lands throws.
Future<void> replaceTrackSettled(
  RTCRtpSender sender,
  MediaStreamTrack? track,
) async {
  await sender.replaceTrack(track);
  if (track == null) return;
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (sender.track?.id != track.id && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Waits for ICE gathering so one offer or answer carries every candidate.
Future<RTCSessionDescription?> gatheredDescription(RTCPeerConnection pc) async {
  if (pc.iceGatheringState !=
      RTCIceGatheringState.RTCIceGatheringStateComplete) {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      final state = await pc.getIceGatheringState();
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return pc.getLocalDescription();
}

Future<LinkStats> linkStats(RTCPeerConnection pc) async {
  final reports = await pc.getStats();
  final tally = LinkTally();
  for (final report in reports) {
    if (report.type == 'inbound-rtp') tally.inbound(report.values);
  }
  return tally.stats(connectionStateOf(pc), roundTrip: roundTripOf(reports));
}
