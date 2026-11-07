@Tags(['relay'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/blossom.dart';
import 'package:moranduba/core/groups/groups.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/groups/mls_native.dart';
import 'package:moranduba/core/groups/rust_group_engine.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';

import '../support/fake_blossom.dart';

// Needs the dev relay: docker compose -f dev/docker-compose.yml up -d
const _relays = ['ws://localhost:7777'];

Future<void> _until(Listenable listenable, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void check() {
    if (condition() && !done.isCompleted) done.complete();
  }

  listenable.addListener(check);
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    listenable.removeListener(check);
  }
}

Future<Session> _start(
  Identity identity,
  SnapshotStore store, {
  BlossomClient? blossom,
}) => Session.start(
  identity,
  relays: _relays,
  blossom: blossom,
  profileStore: MemorySnapshotStore(),
  openGroupEngine: () => RustGroupEngine.open(
    bridge: const NativeMlsBridge(),
    secretKey: identity.privateKey,
    storageKey: '11' * 32,
    store: store,
  ),
);

void main() {
  test('invite over gift wrap, chat, leave, and restart', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final aliceStore = MemorySnapshotStore();
    final alice = await _start(aliceId, aliceStore);
    final bob = await _start(bobId, MemorySnapshotStore());
    addTearDown(bob.close);
    final aliceGroups = alice.groups!;
    final bobGroups = bob.groups!;

    final group = await aliceGroups.create('crew', [bobId.publicKey]);
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    final invite = bobGroups.invites.single;
    expect(invite.groupName, 'crew');
    expect(invite.inviter, aliceId.publicKey);

    await bobGroups.accept(invite.id);
    expect(bobGroups.spaces.single.id, group.id);

    await aliceGroups.send(group.id, 'hello crew');
    await _until(bobGroups, () => bobGroups.messagesIn(group.id).isNotEmpty);
    expect(bobGroups.messagesIn(group.id).single.text, 'hello crew');

    await bobGroups.send(group.id, 'oi');
    await _until(
      aliceGroups,
      () => aliceGroups.messagesIn(group.id).any((m) => m.text == 'oi'),
    );

    await bobGroups.leave(group.id);
    expect(bobGroups.spaces, isEmpty);
    await _until(
      aliceGroups,
      () => aliceGroups.group(group.id)?.memberCount == 1,
    );

    await alice.close();
    final restarted = await _start(aliceId, aliceStore);
    addTearDown(restarted.close);
    final history = restarted.groups!.messagesIn(group.id);
    // Sent within the same second, so either order is fair.
    expect(history.map((m) => m.text), unorderedEquals(['hello crew', 'oi']));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a leave in a trio converges on one commit', () async {
    final ids = [Identity.generate(), Identity.generate(), Identity.generate()];
    final sessions = [
      for (final id in ids) await _start(id, MemorySnapshotStore()),
    ];
    for (final s in sessions) {
      addTearDown(s.close);
    }
    final [alice, bob, carol] = [for (final s in sessions) s.groups!];

    final group = await alice.create('trio', [
      ids[1].publicKey,
      ids[2].publicKey,
    ]);
    for (final g in [bob, carol]) {
      await _until(g, () => g.invites.isNotEmpty);
      await g.accept(g.invites.single.id);
    }

    await bob.leave(group.id);
    for (final g in [alice, carol]) {
      await _until(g, () => g.group(group.id)?.memberCount == 2);
    }

    await carol.send(group.id, 'just us now');
    await _until(
      alice,
      () => alice.messagesIn(group.id).any((m) => m.text == 'just us now'),
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a picture travels encrypted through Blossom', () async {
    final server = await FakeBlossom.start();
    addTearDown(server.close);
    final blossom = BlossomClient(servers: [server.url]);
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final alice = await _start(
      aliceId,
      MemorySnapshotStore(),
      blossom: blossom,
    );
    final bob = await _start(bobId, MemorySnapshotStore(), blossom: blossom);
    addTearDown(alice.close);
    addTearDown(bob.close);

    final group = await alice.groups!.create('pics', [bobId.publicKey]);
    final bobGroups = bob.groups!;
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    await bobGroups.accept(bobGroups.invites.single.id);

    // 1x1 PNG.
    final png = base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    await alice.groups!.sendFile(
      group.id,
      png,
      mime: 'image/png',
      filename: 'dot.png',
      caption: 'look',
    );
    expect(server.blobs.values.single, isNot(png));

    await _until(
      bobGroups,
      () => bobGroups.messagesIn(group.id).any((m) => m.media.isNotEmpty),
    );
    final message = bobGroups.messagesIn(group.id).single;
    expect(message.text, 'look');
    final picture = await bobGroups.media(group.id, message.media.single);
    expect(picture.sublist(0, 8), png.sublist(0, 8));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('group members see names of people they never befriended', () async {
    final ids = [Identity.generate(), Identity.generate(), Identity.generate()];
    final [alice, bob, carol] = [
      for (final id in ids) await _start(id, MemorySnapshotStore()),
    ];
    for (final s in [alice, bob, carol]) {
      addTearDown(s.close);
    }
    await alice.updateProfile(name: 'Alice');
    final group = await alice.groups!.create('crew', [ids[1].publicKey]);
    final bobGroups = bob.groups!;
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    await bobGroups.accept(bobGroups.invites.single.id);
    await _until(bob, () => bob.displayName(ids[0].publicKey) == 'Alice');

    // Carol joins later, on a new epoch, and still gets it.
    await alice.groups!.addMembers(group.id, [ids[2].publicKey]);
    final carolGroups = carol.groups!;
    await _until(carolGroups, () => carolGroups.invites.isNotEmpty);
    await carolGroups.accept(carolGroups.invites.single.id);
    await _until(carol, () => carol.displayName(ids[0].publicKey) == 'Alice');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('creating a group with someone who has no key package fails', () async {
    final alice = await _start(Identity.generate(), MemorySnapshotStore());
    addTearDown(alice.close);
    await expectLater(
      alice.groups!.create('solo', [Identity.generate().publicKey]),
      throwsA(isA<MissingKeyPackage>()),
    );
  });
}
