@Tags(['relay'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/expiry.dart';
import 'package:moranduba/core/friend_protocol.dart';
import 'package:moranduba/core/groups/blossom.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';

import '../support/fake_blossom.dart';

// Needs the dev relay: docker compose -f dev/docker-compose.yml up -d
const _relays = ['ws://localhost:7777'];

/// In-memory stores; sessions sharing one factory see each other's data,
/// like a restart on the same device.
Future<SnapshotStore> Function(String) _memory() {
  final stores = <String, MemorySnapshotStore>{};
  return (name) async => stores.putIfAbsent(name, MemorySnapshotStore.new);
}

Future<void> _until(Session session, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void check() {
    if (condition() && !done.isCompleted) done.complete();
  }

  session.addListener(check);
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } finally {
    session.removeListener(check);
  }
}

void main() {
  test('request, accept, chat, and friend list survives restart', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final aliceStores = _memory();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      openStore: aliceStores,
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      openStore: _memory(),
    );
    addTearDown(alice.close);
    addTearDown(bob.close);

    await alice.requestFriend(bobId.publicKey, note: 'hi, it is alice');
    await _until(alice, () => alice.outgoingRequests.contains(bobId.publicKey));
    await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));

    await bob.acceptFriend(aliceId.publicKey);
    await _until(alice, () => alice.friends.contains(bobId.publicKey));
    expect(bob.stateOf(aliceId.publicKey), FriendState.friend);

    await alice.sendText(bobId.publicKey, 'first message');
    await _until(bob, () => bob.chatWith(aliceId.publicKey).isNotEmpty);
    final received = bob.chatWith(aliceId.publicKey).single;
    expect(received.content, 'first message');
    expect(received.isOutgoing, isFalse);
    // The sender's own copy comes back through the relay.
    await _until(alice, () => alice.chatWith(bobId.publicKey).isNotEmpty);
    expect(alice.chatWith(bobId.publicKey).single.isOutgoing, isTrue);

    // close() flushes the pending friend-list write.
    await alice.close();
    final restarted = await Session.start(
      aliceId,
      relays: _relays,
      openStore: aliceStores,
    );
    addTearDown(restarted.close);
    expect(restarted.stateOf(bobId.publicKey), FriendState.friend);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('DM history comes back from the device when no relay answers', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final bobStores = _memory();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      openStore: _memory(),
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      openStore: bobStores,
    );
    addTearDown(alice.close);

    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));
    await bob.acceptFriend(aliceId.publicKey);
    await _until(alice, () => alice.friends.contains(bobId.publicKey));
    await alice.sendText(bobId.publicKey, 'kept on the device');
    await _until(bob, () => bob.chatWith(aliceId.publicKey).isNotEmpty);
    await bob.close();

    final offline = await Session.start(
      bobId,
      relays: const ['ws://localhost:1'],
      openStore: bobStores,
    );
    addTearDown(offline.close);
    expect(
      offline.chatWith(aliceId.publicKey).single.content,
      'kept on the device',
    );
    expect(offline.friends, contains(aliceId.publicKey));
    final hits = offline.search('ON THE device');
    expect(hits.single.chat, dmChat(aliceId.publicKey));
    expect(hits.single.sender, aliceId.publicKey);
    expect(offline.search('nowhere'), isEmpty);
  });

  test('text typed with no relay waits, then goes out in order', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final aliceStores = _memory();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      openStore: aliceStores,
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      openStore: _memory(),
    );
    addTearDown(bob.close);
    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));
    await bob.acceptFriend(aliceId.publicKey);
    await _until(alice, () => alice.friends.contains(bobId.publicKey));
    await alice.close();

    final offline = await Session.start(
      aliceId,
      relays: const ['ws://localhost:1'],
      openStore: aliceStores,
    );
    await offline.sendText(bobId.publicKey, 'one');
    await offline.sendText(bobId.publicKey, 'two');
    expect(
      [for (final p in offline.outbox.inChat(dmChat(bobId.publicKey))) p.text],
      ['one', 'two'],
    );
    await offline.close();

    final online = await Session.start(
      aliceId,
      relays: _relays,
      openStore: aliceStores,
    );
    addTearDown(online.close);
    await _until(bob, () => bob.chatWith(aliceId.publicKey).length == 2);
    expect(
      [for (final m in bob.chatWith(aliceId.publicKey)) m.content],
      ['one', 'two'],
    );
    await _until(online, () => online.outbox.all.isEmpty);
  });

  test('an acceptance with no relay waits, then reaches them', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final bobStores = _memory();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      openStore: _memory(),
    );
    addTearDown(alice.close);
    final bob = await Session.start(
      bobId,
      relays: _relays,
      openStore: bobStores,
    );
    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));
    await bob.close();

    final offline = await Session.start(
      bobId,
      relays: const ['ws://localhost:1'],
      openStore: bobStores,
    );
    await offline.acceptFriend(aliceId.publicKey);
    expect(offline.stateOf(aliceId.publicKey), FriendState.friend);
    expect(offline.outbox.inChat(dmChat(aliceId.publicKey)), hasLength(1));
    await offline.close();

    final online = await Session.start(
      bobId,
      relays: _relays,
      openStore: bobStores,
    );
    addTearDown(online.close);
    await _until(alice, () => alice.friends.contains(bobId.publicKey));
    await _until(online, () => online.outbox.all.isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('friends see each other online; strangers learn nothing', () async {
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final carolId = Identity.generate();
    final [alice, bob, carol] = [
      for (final id in [aliceId, bobId, carolId])
        await Session.start(id, relays: _relays, openStore: _memory()),
    ];
    addTearDown(alice.close);
    addTearDown(bob.close);
    addTearDown(carol.close);

    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.incomingRequests.isNotEmpty);
    await bob.acceptFriend(aliceId.publicKey);
    // Both hold the other's key once the profile batch went out.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (alice.presence.book.theirs[bobId.publicKey] == null ||
        bob.presence.book.theirs[aliceId.publicKey] == null) {
      if (DateTime.now().isAfter(deadline)) fail('keys never arrived');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(bob.chatWith(aliceId.publicKey), isEmpty);

    // No beat is due for minutes: hellos and their answers do it.
    while (!bob.presence.isOnline(aliceId.publicKey) ||
        !alice.presence.isOnline(bobId.publicKey)) {
      if (DateTime.now().isAfter(deadline.add(const Duration(seconds: 10)))) {
        fail('presence never arrived');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(carol.presence.isOnline(aliceId.publicKey), isFalse);
    expect(carol.presence.book.theirs, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('profiles reach friends, including pictures and edits', () async {
    final server = await FakeBlossom.start();
    addTearDown(server.close);
    final blossom = BlossomClient(servers: [server.url]);
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      openStore: _memory(),
      blossom: blossom,
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      openStore: _memory(),
      blossom: blossom,
    );
    addTearDown(alice.close);
    addTearDown(bob.close);

    final picture = Uint8List.fromList(List.generate(64, (i) => i));
    await alice.updateProfile(
      name: 'Alice',
      picture: picture,
      mime: 'image/png',
    );
    expect(server.blobs.values.single, isNot(picture));
    expect(alice.displayName(aliceId.publicKey), 'Alice');

    // The request carries the profile, so Bob sees who is asking.
    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.displayName(aliceId.publicKey) == 'Alice');
    expect(await bob.picture(aliceId.publicKey), picture);
    // Profile control messages stay out of the chat.
    expect(bob.chatWith(aliceId.publicKey), isEmpty);

    await bob.updateProfile(name: 'Bob');
    await bob.acceptFriend(aliceId.publicKey);
    await _until(alice, () => alice.displayName(bobId.publicKey) == 'Bob');

    await alice.updateProfile(name: 'Alice B.', removePicture: true);
    await _until(bob, () => bob.displayName(aliceId.publicKey) == 'Alice B.');
    expect(await bob.picture(aliceId.publicKey), isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'disappearing DMs: both sides get the timer and drop old messages',
    () async {
      final aliceId = Identity.generate();
      final bobId = Identity.generate();
      final alice = await Session.start(
        aliceId,
        relays: _relays,
        openStore: _memory(),
      );
      final bob = await Session.start(
        bobId,
        relays: _relays,
        openStore: _memory(),
      );
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.requestFriend(bobId.publicKey);
      await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));
      await bob.acceptFriend(aliceId.publicKey);
      await _until(alice, () => alice.friends.contains(bobId.publicKey));

      await alice.sendText(bobId.publicKey, 'kept until the timer starts');
      await _until(bob, () => bob.chatWith(aliceId.publicKey).isNotEmpty);

      await alice.setExpiry(dmChat(bobId.publicKey), 4);
      await _until(bob, () => bob.expiryOf(dmChat(aliceId.publicKey)).isOn);
      expect(bob.expiryOf(dmChat(aliceId.publicKey)).seconds, 4);
      // The old message is already past 4 seconds or will be shortly.
      await alice.sendText(bobId.publicKey, 'gone in 4');
      await _until(
        bob,
        () => bob
            .chatWith(aliceId.publicKey)
            .any((m) => m.content == 'gone in 4'),
      );
      final expiring = bob
          .chatWith(aliceId.publicKey)
          .firstWhere((m) => m.content == 'gone in 4');
      expect(expiring.rumor.tags.any((t) => t.first == 'expiration'), isTrue);

      await Future<void>.delayed(const Duration(seconds: 5));
      await bob.pruneExpired();
      await alice.pruneExpired();
      expect(bob.chatWith(aliceId.publicKey), isEmpty);
      expect(alice.chatWith(bobId.publicKey), isEmpty);
      // Friendship lives in control messages, which never expire.
      expect(bob.stateOf(aliceId.publicKey), FriendState.friend);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('files in DMs travel encrypted, with or without a timer', () async {
    final server = await FakeBlossom.start();
    addTearDown(server.close);
    final blossom = BlossomClient(servers: [server.url]);
    final aliceId = Identity.generate();
    final bobId = Identity.generate();
    Future<Session> start(Identity id) => Session.start(
      id,
      relays: _relays,
      openStore: _memory(),
      blossom: blossom,
    );
    final alice = await start(aliceId);
    final bob = await start(bobId);
    addTearDown(alice.close);
    addTearDown(bob.close);
    await alice.requestFriend(bobId.publicKey);
    await _until(bob, () => bob.incomingRequests.contains(aliceId.publicKey));
    await bob.acceptFriend(aliceId.publicKey);
    await _until(alice, () => alice.friends.contains(bobId.publicKey));

    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.4 tiny'));
    await alice.sendFile(
      bobId.publicKey,
      pdf,
      mime: 'application/pdf',
      filename: 'brief.pdf',
    );
    expect(server.blobs.values.single, isNot(pdf));
    await _until(bob, () => bob.chatWith(aliceId.publicKey).isNotEmpty);
    final received = bob.chatWith(aliceId.publicKey).single;
    expect(dmFileName(received), 'brief.pdf');
    expect(received.fileMetadata?.mimeType, 'application/pdf');
    expect(await bob.dmFile(received), pdf);

    await alice.setExpiry(dmChat(bobId.publicKey), 3600);
    final wav = Uint8List.fromList(List.generate(100, (i) => i));
    await alice.sendFile(
      bobId.publicKey,
      wav,
      mime: 'audio/wav',
      filename: 'tone.wav',
    );
    await _until(bob, () => bob.chatWith(aliceId.publicKey).length == 2);
    final timed = bob.chatWith(aliceId.publicKey).last;
    expect(dmFileName(timed), 'tone.wav');
    expect(timed.rumor.tags.any((t) => t.first == 'expiration'), isTrue);
    expect(await bob.dmFile(timed), wav);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
