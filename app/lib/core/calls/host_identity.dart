import 'dart:convert';

/// What the SFU binary prints once it is up (ADR 0002, sidecar line).
class HostIdentity {
  const HostIdentity({
    required this.pubkey,
    required this.npub,
    required this.claimCode,
  });

  static const prefix = 'MORANDUBA_SFU ';

  final String pubkey;
  final String npub;

  /// Empty once someone claimed it.
  final String claimCode;

  static HostIdentity? parse(String line) {
    if (!line.startsWith(prefix)) return null;
    try {
      if (jsonDecode(line.substring(prefix.length)) case {
        'pubkey': final String pubkey,
        'npub': final String npub,
        'claim_code': final String claimCode,
      }) {
        return HostIdentity(pubkey: pubkey, npub: npub, claimCode: claimCode);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// A running SFU on this machine.
abstract interface class HostedSfu {
  HostIdentity get identity;
  Future<void> stop();
}
