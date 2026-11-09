import 'dart:convert';

import 'relay_plan.dart';

/// Call signaling carried as MLS application messages inside the group.
/// Shape is ours and *provisional*.
enum SignalType {
  join,
  here,
  leave,
  offer,
  answer,

  /// A relay member's offer carrying [CallSignal.origin]'s media, and the
  /// answer to it (ADR 0003).
  relayOffer('relay_offer'),
  relayAnswer('relay_answer'),
  switchMode('switch'),

  /// Rings [CallSignal.to], or every member not in the call, into it.
  ring;

  const SignalType([this._wire]);

  final String? _wire;

  String get wire => _wire ?? name;

  static SignalType? parse(String wire) =>
      values.where((t) => t.wire == wire).firstOrNull;
}

/// What a participant is sending; drives the tile shown to others.
class MediaState {
  const MediaState({this.audio = true, this.video = true, this.screen = false});

  final bool audio;
  final bool video;
  final bool screen;

  Map<String, bool> toJson() => {
    'audio': audio,
    'video': video,
    'screen': screen,
  };

  static MediaState fromJson(Object? json) => switch (json) {
    {
      'audio': final bool audio,
      'video': final bool video,
      'screen': final bool screen,
    } =>
      MediaState(audio: audio, video: video, screen: screen),
    _ => const MediaState(),
  };
}

class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    this.to,
    this.sdp,
    this.media = const MediaState(),
    this.mode,
    this.sfu,
    this.seq = 0,
    this.origin,
    this.report,
  });

  final SignalType type;
  final String callId;

  /// Recipient pubkey for offers, answers and rings; null means everyone.
  final String? to;
  final String? sdp;
  final MediaState media;

  /// Transport in use, or switched to: `mesh`, `host_peer`, `server`.
  final String? mode;

  /// The SFU (hex pubkey) behind [mode], outside mesh.
  final String? sfu;
  final int seq;

  /// Whose media a relay link carries.
  final String? origin;

  /// The sender's direct links, in mesh presence.
  final LinkReport? report;

  String encode() => jsonEncode({
    't': type.wire,
    'call': callId,
    'to': ?to,
    'sdp': ?sdp,
    'media': media.toJson(),
    'mode': ?mode,
    'sfu': ?sfu,
    if (seq != 0) 'seq': seq,
    'origin': ?origin,
    if (report case final report?) ...{
      'links': [...report.links],
      'failed': [...report.failed],
    },
  });

  static CallSignal? decode(String payload) {
    final Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (json case {'t': final String t, 'call': final String callId}) {
      final type = SignalType.parse(t);
      if (type == null) return null;
      return CallSignal(
        type: type,
        callId: callId,
        to: switch (json['to']) {
          final String to => to,
          _ => null,
        },
        sdp: switch (json['sdp']) {
          final String sdp => sdp,
          _ => null,
        },
        media: MediaState.fromJson(json['media']),
        mode: switch (json['mode']) {
          final String mode => mode,
          _ => null,
        },
        sfu: switch (json['sfu']) {
          final String sfu => sfu,
          _ => null,
        },
        seq: switch (json['seq']) {
          final int seq => seq,
          _ => 0,
        },
        origin: switch (json['origin']) {
          final String origin => origin,
          _ => null,
        },
        report: switch ((json['links'], json['failed'])) {
          (final List<Object?> links, final List<Object?> failed) => LinkReport(
            links: links.whereType<String>().toSet(),
            failed: failed.whereType<String>().toSet(),
          ),
          _ => null,
        },
      );
    }
    return null;
  }
}
