import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/group_engine.dart';
import 'package:moranduba/core/groups/groups.dart';
import 'package:moranduba/core/groups/space.dart';
import 'package:ndk/ndk.dart';

Nip01Event _keyPackage(String pubkey, {List<List<String>> tags = const []}) =>
    Nip01Event(
      pubKey: pubkey,
      kind: MarmotKind.keyPackage,
      tags: tags,
      content: '',
    );

String _rumor({String? references}) => jsonEncode({
  'kind': MarmotKind.welcome,
  'tags': [
    if (references != null) ['e', references],
    ['relays', 'wss://relay.test'],
  ],
});

void main() {
  test('welcomes pair with the key package their e tag references', () {
    final a = _keyPackage('a' * 64);
    final b = _keyPackage('b' * 64);
    final pairs = pairWelcomes(
      [_rumor(references: b.id), _rumor(references: a.id)],
      [a, b],
    );
    expect(pairs.map((p) => p.$2.pubKey), ['b' * 64, 'a' * 64]);
  });

  test('welcomes without an e tag fall back to list order', () {
    final a = _keyPackage('a' * 64);
    expect(pairWelcomes([_rumor()], [a]).single.$2, same(a));
    expect(() => pairWelcomes([_rumor(), _rumor()], [a]), throwsStateError);
  });

  test('key package relays come from its relays tag', () {
    final package = _keyPackage(
      'a' * 64,
      tags: [
        ['relays', 'wss://one', 'wss://two'],
        ['mls_protocol_version', '1.0'],
      ],
    );
    expect(keyPackageRelays(package), ['wss://one', 'wss://two']);
  });

  test('a v1 space is one channel with chat and calls', () {
    const group = GroupInfo(
      id: 'g1',
      nostrGroupId: 'n1',
      name: 'crew',
      relays: [],
      admins: [],
      memberCount: 2,
    );
    final space = Space.fromGroup(group);
    expect(space.main.mlsGroupId, 'g1');
    expect(space.main.kinds, {ChannelKind.text, ChannelKind.voice});
  });
}
