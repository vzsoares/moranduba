import 'dart:convert';

export 'push_io.dart' if (dart.library.js_interop) 'push_web.dart';

/// Where one device receives Web Push messages, as an SFU stores it.
class PushTarget {
  const PushTarget({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });

  final String endpoint;

  /// Base64url, unpadded.
  final String p256dh;
  final String auth;

  Map<String, Object> toRequest() => {
    'type': 'push_subscribe',
    'endpoint': endpoint,
    'p256dh': p256dh,
    'auth': auth,
  };
}

/// A push from an SFU: someone started call [callId], or it stopped ringing.
class PushRing {
  const PushRing({
    required this.stop,
    required this.from,
    required this.callId,
  });

  final bool stop;

  /// Caller pubkey, hex.
  final String from;
  final String callId;

  static PushRing? decode(String text) {
    try {
      return switch (jsonDecode(text)) {
        {
          't': final String t,
          'from': final String from,
          'call': final String call,
        }
            when t == 'ring' || t == 'stop' =>
          PushRing(stop: t == 'stop', from: from, callId: call),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}
