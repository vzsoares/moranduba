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
    final aliceProfiles = MemorySnapshotStore();
    final alice = await Session.start(
      aliceId,
      relays: _relays,
      profileStore: aliceProfiles,
      expiryStore: MemorySnapshotStore(),
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      profileStore: MemorySnapshotStore(),
      expiryStore: MemorySnapshotStore(),
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
      profileStore: aliceProfiles,
      expiryStore: MemorySnapshotStore(),
    );
    addTearDown(restarted.close);
    expect(restarted.stateOf(bobId.publicKey), FriendState.friend);
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
      blossom: blossom,
      profileStore: MemorySnapshotStore(),
      expiryStore: MemorySnapshotStore(),
    );
    final bob = await Session.start(
      bobId,
      relays: _relays,
      blossom: blossom,
      profileStore: MemorySnapshotStore(),
      expiryStore: MemorySnapshotStore(),
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
        profileStore: MemorySnapshotStore(),
        expiryStore: MemorySnapshotStore(),
      );
      final bob = await Session.start(
        bobId,
        relays: _relays,
        profileStore: MemorySnapshotStore(),
        expiryStore: MemorySnapshotStore(),
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
      blossom: blossom,
      profileStore: MemorySnapshotStore(),
      expiryStore: MemorySnapshotStore(),
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
