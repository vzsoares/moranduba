import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/presence.dart';

void main() {
  final key = 'ab' * 32;
  final start = DateTime.fromMillisecondsSinceEpoch(
    presenceWindow.inMilliseconds * 1000,
  );

  test('a tag holds for its window and changes with window and key', () {
    final tag = presenceTag(key, start);
    expect(tag, hasLength(32));
    expect(presenceTag(key, start.add(const Duration(minutes: 9))), tag);
    expect(presenceTag(key, start.add(presenceWindow)), isNot(tag));
    expect(presenceTag('cd' * 32, start), isNot(tag));
  });

  test('keys decode only when well formed', () {
    final known = PresenceKey(key, const ['wss://a']);
    final decoded = PresenceKey.decode(known.encode());
    expect(decoded?.key, key);
    expect(decoded?.relays, ['wss://a']);
    expect(PresenceKey.decode('{"key":"short","relays":[]}'), isNull);
    expect(PresenceKey.decode('not json'), isNull);
  });

  test('the book keeps our key, who has it, and friends keys', () async {
    final store = MemorySnapshotStore();
    final book = PresenceBook(store);
    await book.load();
    expect(book.mine, hasLength(64));
    expect(book.needsSending('bob'), isTrue);
    expect(book.sharedWithAnyone, isFalse);
    await book.markSent('bob');
    expect(await book.learn('bob', PresenceKey(key, const [])), isTrue);
    expect(await book.learn('bob', PresenceKey(key, const [])), isFalse);

    final reloaded = PresenceBook(store);
    await reloaded.load();
    expect(reloaded.mine, book.mine);
    expect(reloaded.needsSending('bob'), isFalse);
    expect(reloaded.sharedWithAnyone, isTrue);
    expect(reloaded.theirs['bob']?.key, key);
    expect(reloaded.hidden, isFalse);

    await reloaded.setHidden(true);
    final hidden = PresenceBook(store);
    await hidden.load();
    expect(hidden.hidden, isTrue);
  });

  test('pings say hello or bye, anything else is a beat', () {
    expect(Beat.of('hello'), Beat.hello);
    expect(Beat.of('bye'), Beat.bye);
    expect(Beat.of(''), Beat.alive);
    expect(Beat.of('other'), Beat.alive);
  });
}
