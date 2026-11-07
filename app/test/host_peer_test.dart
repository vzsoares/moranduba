import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/calls.dart';
import 'package:moranduba/core/calls/sfu_book.dart';
import 'package:moranduba/core/calls/sfu_client.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';

final _a = 'a' * 64;
final _b = 'b' * 64;
final _c = 'c' * 64;

void main() {
  test(
    'host entries merge newest-wins per pubkey and survive a reload',
    () async {
      final store = MemorySnapshotStore();
      final book = SfuBook(store);
      expect(
        await book.putHosts('g1', {
          _a: const HostPeer(on: true, setAt: 10),
          _b: const HostPeer(on: true, setAt: 20),
        }),
        isTrue,
      );
      expect(book.hostsOf('g1'), [_b, _a]);

      expect(
        await book.putHosts('g1', {_a: const HostPeer(on: false, setAt: 5)}),
        isFalse,
      );
      expect(
        await book.putHosts('g1', {_a: const HostPeer(on: false, setAt: 30)}),
        isTrue,
      );
      expect(book.hostsOf('g1'), [_b]);
      expect(book.groupsOn(_b), ['g1']);
      expect(book.groupsOn(_a), isEmpty);

      final reloaded = SfuBook(store);
      await reloaded.load();
      expect(reloaded.hostsOf('g1'), [_b]);
      expect(reloaded.host('g1', _a)?.on, isFalse);
    },
  );

  test('host maps drop malformed entries', () {
    expect(
      hostPeersFromJson({
        _a: {'on': true, 'set_at': 1},
        'not-a-key': {'on': true, 'set_at': 1},
        _b: {'on': 'yes', 'set_at': 1},
      }).keys,
      [_a],
    );
    expect(hostPeersFromJson('nope'), isEmpty);
  });

  group('pickSfu', () {
    Future<Map<String, Object?>> Function(String) pings(
      Map<String, Object> answers,
    ) =>
        (sfu) async => switch (answers[sfu]) {
          final Map<String, Object?> pong => pong,
          final Object error => throw error,
          null => throw const SfuException('timeout'),
        };

    test('takes the server when it answers', () async {
      final picked = await pickSfu(
        [('server', _a), ('host_peer', _b)],
        ping: pings({
          _a: {'allowed': true},
          _b: {'allowed': true},
        }),
      );
      expect((picked?.mode, picked?.sfu), ('server', _a));
    });

    test('falls to the first host peer that knows us', () async {
      final problems = <String>[];
      final picked = await pickSfu(
        [('server', _a), ('host_peer', _b), ('host_peer', _c)],
        ping: pings({
          _b: {'allowed': false},
          _c: {'allowed': true},
        }),
        onProblem: (mode, _) => problems.add(mode),
      );
      expect((picked?.mode, picked?.sfu), ('host_peer', _c));
      expect(problems, unorderedEquals(['server', 'host_peer']));
    });

    test('returns null when nothing answers', () async {
      expect(await pickSfu([('host_peer', _b)], ping: pings({})), isNull);
    });

    test('a dead first choice costs one wait, not one per candidate', () async {
      final watch = Stopwatch()..start();
      final picked = await pickSfu(
        [('server', _a), ('host_peer', _b), ('host_peer', _c)],
        ping: (sfu) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (sfu == _c) return {'allowed': true};
          throw const SfuException('timeout');
        },
      );
      expect(picked?.sfu, _c);
      expect(watch.elapsedMilliseconds, lessThan(400));
    });
  });
}
