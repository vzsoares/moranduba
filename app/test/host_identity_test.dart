import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/host_identity.dart';

void main() {
  test('reads the SFU identity line and ignores everything else', () {
    final identity = HostIdentity.parse(
      'MORANDUBA_SFU {"pubkey":"${'a' * 64}","npub":"npub1x",'
      '"claim_code":"K7Q2","turn_port":3478}',
    );
    expect(identity?.pubkey, 'a' * 64);
    expect(identity?.claimCode, 'K7Q2');
    expect(HostIdentity.parse('npub: npub1x'), isNull);
    expect(HostIdentity.parse('MORANDUBA_SFU {broken'), isNull);
    expect(HostIdentity.parse('MORANDUBA_SFU {"pubkey":"x"}'), isNull);
  });
}
