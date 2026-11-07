import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/expiry.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';

void main() {
  test('timers decode defensively and label the presets', () {
    const timer = ChatExpiry(seconds: 86400, setAt: 7);
    expect(ChatExpiry.fromJson(timer.toJson())?.seconds, 86400);
    expect(ChatExpiry.decode('{"seconds":-1,"set_at":1}'), isNull);
    expect(ChatExpiry.decode('nope'), isNull);
    expect(
      [for (final s in expiryChoices) expiryLabel(s)],
      ['Off', '1 hour', '24 hours', '1 week'],
    );
  });

  test('newest timer wins and survives a reload', () async {
    final store = MemorySnapshotStore();
    final book = ExpiryBook(store);
    final chat = groupChat('g1');
    expect(book.of(chat).isOn, isFalse);
    expect(
      await book.put(chat, const ChatExpiry(seconds: 3600, setAt: 10)),
      isTrue,
    );
    expect(
      await book.put(chat, const ChatExpiry(seconds: 0, setAt: 9)),
      isFalse,
    );
    await book.markAnnounced(chat, 4);

    final reloaded = ExpiryBook(store);
    await reloaded.load();
    expect(reloaded.of(chat).seconds, 3600);
    expect(reloaded.announcedOn(chat, 4), isTrue);
    expect(reloaded.announcedOn(chat, 5), isFalse);
    expect(reloaded.active.single.key, chat);
  });
}
