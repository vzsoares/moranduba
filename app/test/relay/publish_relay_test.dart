@Tags(['relay'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/publish.dart';
import 'package:ndk/ndk.dart';

// Needs the dev relay: docker compose -f dev/docker-compose.yml up -d
const _relay = 'ws://localhost:7777';

/// A relay that takes connections and never answers.
Future<HttpServer> _silentRelay() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((_) {});
  });
  return server;
}

void main() {
  test('a publish is done once one relay takes it', () async {
    final silent = await _silentRelay();
    addTearDown(() => silent.close(force: true));
    final identity = Identity.generate();
    final ndk = Ndk(
      NdkConfig(cache: MemCacheManager(), eventVerifier: Bip340EventVerifier()),
    );
    addTearDown(ndk.destroy);
    ndk.accounts.loginPrivateKey(
      pubkey: identity.publicKey,
      privkey: identity.privateKey,
    );
    final watch = Stopwatch()..start();
    final taken = await acceptedByAny(
      ndk.broadcast.broadcast(
        nostrEvent: Nip01Event(
          pubKey: identity.publicKey,
          kind: 1,
          tags: const [],
          content: 'hello',
        ),
        specificRelays: [_relay, 'ws://localhost:${silent.port}'],
      ),
    );
    expect(taken, isTrue);
    // ndk's own done future waits 10 s for the silent relay.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
