import 'dart:convert';

/// Call signaling carried as MLS application messages inside the group.
/// Shape is ours and *provisional*.
enum SignalType {
  join,
  here,
  leave,
  offer,
  answer,
  switchMode('switch');

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
    this.seq = 0,
  });

  final SignalType type;
  final String callId;

  /// Recipient pubkey for offers and answers; null means everyone.
  final String? to;
  final String? sdp;
  final MediaState media;

  /// Transport for [SignalType.switchMode]: `mesh`, `host_peer`, `server`.
  final String? mode;
  final int seq;

  String encode() => jsonEncode({
    't': type.wire,
    'call': callId,
    'to': ?to,
    'sdp': ?sdp,
    'media': media.toJson(),
    'mode': ?mode,
    if (seq != 0) 'seq': seq,
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
        seq: switch (json['seq']) {
          final int seq => seq,
          _ => 0,
        },
      );
    }
    return null;
  }
}
