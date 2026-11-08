import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/network.dart';

void main() {
  test('relay addresses get wss and lose a trailing slash', () {
    expect(relayUrl('relay.example.com'), 'wss://relay.example.com');
    expect(relayUrl(' ws://localhost:7777/ '), 'ws://localhost:7777');
    expect(relayUrl('https://relay.example.com'), isNull);
    expect(relayUrl('wss://'), isNull);
    expect(relayUrl(''), isNull);
  });

  test('Blossom addresses get https', () {
    expect(blossomUrl('files.example.com'), 'https://files.example.com');
    expect(blossomUrl('http://localhost:8800/'), 'http://localhost:8800');
    expect(blossomUrl('wss://files.example.com'), isNull);
  });

  test('saved lists come back; empty ones mean the defaults', () async {
    final store = MemorySnapshotStore();
    final book = NetworkBook(store);
    await book.save(relays: ['wss://a.example'], blossom: const []);

    final again = NetworkBook(store);
    await again.load();
    expect(again.relays, ['wss://a.example']);
    expect(again.blossom, isNull);

    await again.wipe();
    final wiped = NetworkBook(store);
    await wiped.load();
    expect(wiped.relays, isNull);
  });
}
