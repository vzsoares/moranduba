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
  });

  final String state;
  final int framesDecoded;
  final int audioPackets;

  Map<String, Object> toJson() => {
    'state': state,
    'framesDecoded': framesDecoded,
    'audioPackets': audioPackets,
  };
}

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
  var frames = 0;
  var packets = 0;
  for (final report in await pc.getStats()) {
    if (report.type != 'inbound-rtp') continue;
    final values = report.values;
    if (values['kind'] == 'video') {
      frames += switch (values['framesDecoded']) {
        final num n => n.toInt(),
        _ => 0,
      };
    } else if (values['kind'] == 'audio') {
      packets += switch (values['packetsReceived']) {
        final num n => n.toInt(),
        _ => 0,
      };
    }
  }
  final state =
      pc.connectionState?.name.replaceFirst('RTCPeerConnectionState', '') ??
      'new';
  return LinkStats(state: state, framesDecoded: frames, audioPackets: packets);
}
