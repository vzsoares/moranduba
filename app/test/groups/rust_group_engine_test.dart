import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/group_engine.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/groups/mls_native.dart';
import 'package:moranduba/core/groups/rust_group_engine.dart';
import 'package:moranduba/core/identity.dart';

const _relays = ['wss://relay.test'];

class _Peer {
  _Peer() : identity = Identity.generate();

  final Identity identity;
  final store = MemorySnapshotStore();
  late RustGroupEngine engine;

  Future<void> open() async {
    engine = await RustGroupEngine.open(
      bridge: const NativeMlsBridge(),
      secretKey: identity.privateKey,
      storageKey: 'ab' * 32,
      store: store,
    );
  }

  Future<void> join(String welcome) async {
    await engine.receiveWelcome('cd' * 32, welcome);
    final invites = await engine.invites();
    await engine.acceptInvite(invites.single.id);
  }
}

void main() {
  test('create, join, chat and restart through the FFI engine', () async {
    final alice = _Peer();
    final bob = _Peer();
    await alice.open();
    await bob.open();

    final created = await alice.engine.create(
      name: 'Moranduba',
      relays: _relays,
      memberKeyPackages: [await bob.engine.signedKeyPackage(_relays)],
    );
    expect(created.group.admins, hasLength(2));
    await bob.join(created.welcomeRumors.single);

    final invite = (await bob.engine.groups()).single;
    expect(invite.name, 'Moranduba');
    expect(invite.memberCount, 2);

    final event = await alice.engine.encryptText(created.group.id, 'oi bob');
    final GroupReceipt receipt = await bob.engine.receive(event);
    expect(receipt.message?.text, 'oi bob');
    expect(receipt.message?.sender, alice.identity.publicKey);

    await bob.engine.close();
    expect(bob.store.value, isNotNull);
    await bob.open();
    final history = await bob.engine.messages(created.group.id);
    expect(history.map((m) => m.text), ['oi bob']);

    await expectLater(bob.engine.members('00'), throwsA(isA<MlsException>()));
  });
}
