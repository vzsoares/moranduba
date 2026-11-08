import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/outbox.dart';

void main() {
  test('queued tags survive a restart', () async {
    final store = MemorySnapshotStore();
    final outbox = Outbox(store);
    await outbox.add(
      'dm:peer',
      'Accepted your friend request',
      tags: const [
        ['moranduba', 'friend_accept'],
      ],
    );
    await outbox.add('dm:peer', 'hi');
    final restored = Outbox(store);
    await restored.load();
    expect(
      [for (final p in restored.all) p.tags],
      [
        [
          ['moranduba', 'friend_accept'],
        ],
        <List<String>>[],
      ],
    );
  });
}
