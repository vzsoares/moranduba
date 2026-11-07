@Tags(['relay'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/call_log.dart';
import 'package:moranduba/core/calls/sfu_client.dart';
import 'package:moranduba/core/expiry.dart';
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
  openStore: (_) async => MemorySnapshotStore(),
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

  test('group timers reach late joiners and prune history', () async {
    final ids = [Identity.generate(), Identity.generate(), Identity.generate()];
    final [alice, bob, carol] = [
      for (final id in ids) await _start(id, MemorySnapshotStore()),
    ];
    for (final s in [alice, bob, carol]) {
      addTearDown(s.close);
    }
    final group = await alice.groups!.create('brief', [ids[1].publicKey]);
    final chat = groupChat(group.id);
    final bobGroups = bob.groups!;
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    await bobGroups.accept(bobGroups.invites.single.id);

    await alice.setExpiry(chat, 4);
    await _until(bob, () => bob.expiryOf(chat).seconds == 4);
    await alice.sendToGroup(group.id, 'short lived');
    await _until(
      bobGroups,
      () => bobGroups.messagesIn(group.id).any((m) => m.text == 'short lived'),
    );

    await alice.groups!.addMembers(group.id, [ids[2].publicKey]);
    final carolGroups = carol.groups!;
    await _until(carolGroups, () => carolGroups.invites.isNotEmpty);
    await carolGroups.accept(carolGroups.invites.single.id);
    await _until(carol, () => carol.expiryOf(chat).seconds == 4);

    await Future<void>.delayed(const Duration(seconds: 5));
    await bob.pruneExpired();
    expect(bobGroups.messagesIn(group.id), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('call events reach members; the log switch is shared', () async {
    final ids = [Identity.generate(), Identity.generate()];
    final [alice, bob] = [
      for (final id in ids) await _start(id, MemorySnapshotStore()),
    ];
    addTearDown(alice.close);
    addTearDown(bob.close);
    final group = await alice.groups!.create('calls', [ids[1].publicKey]);
    final bobGroups = bob.groups!;
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    await bobGroups.accept(bobGroups.invites.single.id);
    final notices = <Notice>[];
    final listening = bob.notices.listen(notices.add);
    addTearDown(listening.cancel);

    expect(alice.logsCalls(group.id), isTrue);
    await alice.groups!.send(
      group.id,
      const CallEvent.started('c1').encode(),
      call: true,
    );
    await alice.groups!.send(
      group.id,
      const CallEvent.ended('c1', seconds: 42).encode(),
      call: true,
    );
    await _until(
      bobGroups,
      () => bobGroups.messagesIn(group.id).where((m) => m.call).length == 2,
    );
    final [entry] = withCallLog(bobGroups.messagesIn(group.id));
    expect(entry is CallLogEntry ? entry.seconds : null, 42);
    // The start is news, the end is not.
    expect(notices.map((n) => n.body), ['started a call']);

    await alice.setCallLog(group.id, on: false);
    await _until(bob, () => !bob.logsCalls(group.id));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('custom emojis reach members and late joiners', () async {
    final server = await FakeBlossom.start();
    addTearDown(server.close);
    final blossom = BlossomClient(servers: [server.url]);
    final ids = [Identity.generate(), Identity.generate(), Identity.generate()];
    final [alice, bob, carol] = [
      for (final id in ids)
        await _start(id, MemorySnapshotStore(), blossom: blossom),
    ];
    for (final s in [alice, bob, carol]) {
      addTearDown(s.close);
    }
    final group = await alice.groups!.create('emoji', [ids[1].publicKey]);
    final bobGroups = bob.groups!;
    await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
    await bobGroups.accept(bobGroups.invites.single.id);

    final image = Uint8List.fromList(List.generate(80, (i) => i));
    await alice.addEmoji(group.id, 'zap', image, mime: 'image/png');
    expect(server.blobs.values.single, isNot(image));
    await _until(bob, () => bob.emojisOf(group.id).containsKey('zap'));
    expect(await bob.emojiImage(bob.emojisOf(group.id)['zap']!), image);

    await alice.groups!.addMembers(group.id, [ids[2].publicKey]);
    final carolGroups = carol.groups!;
    await _until(carolGroups, () => carolGroups.invites.isNotEmpty);
    await carolGroups.accept(carolGroups.invites.single.id);
    await _until(carol, () => carol.emojisOf(group.id).containsKey('zap'));

    await bob.removeEmoji(group.id, 'zap');
    await _until(alice, () => alice.emojisOf(group.id).isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'a desktop hosts calls: sidecar starts, gets claimed, lets members in',
    () async {
      final dataDir = await Directory.systemTemp.createTemp('sfu');
      addTearDown(() => dataDir.delete(recursive: true));
      final aliceId = Identity.generate();
      final bobId = Identity.generate();
      final alice = await _start(aliceId, MemorySnapshotStore());
      final bob = await _start(bobId, MemorySnapshotStore());
      addTearDown(alice.close);
      addTearDown(bob.close);
      final group = await alice.groups!.create('hosted', [bobId.publicKey]);
      final bobGroups = bob.groups!;
      await _until(bobGroups, () => bobGroups.invites.isNotEmpty);
      await bobGroups.accept(bobGroups.invites.single.id);

      await alice.hostCalls(group.id, dataDir: dataDir.path);
      final sfu = alice.hosting!.identity.pubkey;
      expect(alice.ownsServer(sfu), isTrue);
      expect((await alice.pingServer(sfu))['owner'], isTrue);
      await _until(bob, () => bob.serverOf(group.id) == sfu);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while ((await bob.pingServer(sfu))['allowed'] != true) {
        if (DateTime.now().isAfter(deadline)) fail('bob never allowed');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      await alice.stopHosting();
      await expectLater(bob.pingServer(sfu), throwsA(isA<SfuException>()));
    },
    skip: Platform.environment['MORANDUBA_SFU_BIN'] == null
        ? 'set MORANDUBA_SFU_BIN to the built sfu binary'
        : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('creating a group with someone who has no key package fails', () async {
    final alice = await _start(Identity.generate(), MemorySnapshotStore());
    addTearDown(alice.close);
    await expectLater(
      alice.groups!.create('solo', [Identity.generate().publicKey]),
      throwsA(isA<MissingKeyPackage>()),
    );
  });
}
