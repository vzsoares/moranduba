@Tags(['relay'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/friend_protocol.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';

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
    final alice = await Session.start(aliceId, relays: _relays);
    final bob = await Session.start(bobId, relays: _relays);
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
    final restarted = await Session.start(aliceId, relays: _relays);
    addTearDown(restarted.close);
    expect(restarted.stateOf(bobId.publicKey), FriendState.friend);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
