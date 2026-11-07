import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/emojis.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/profiles.dart';
import 'package:moranduba/ui/emoji.dart';

const _picture = PictureRef(url: 'u', key: 'k', nonce: 'n', mime: 'image/png');

void main() {
  test('file names become emoji names', () {
    expect(emojiName('Party Parrot.GIF'), 'party_parrot');
    expect(emojiName('  ok!!.png'), 'ok');
    expect(emojiName('x.png'), isNull);
  });

  test('newest entry per name wins, removals included', () async {
    final store = MemorySnapshotStore();
    final book = EmojiBook(store);
    expect(
      await book.put(
        'g',
        const CustomEmoji(name: 'zap', picture: _picture, setAt: 10),
      ),
      isTrue,
    );
    expect(
      await book.put(
        'g',
        const CustomEmoji(name: 'zap', picture: null, setAt: 5),
      ),
      isFalse,
    );
    expect(book.of('g').keys, ['zap']);
    await book.put(
      'g',
      const CustomEmoji(name: 'zap', picture: null, setAt: 11),
    );
    expect(book.of('g'), isEmpty);
    expect(book.entries('g'), hasLength(1));

    final reloaded = EmojiBook(store);
    await reloaded.load();
    expect(reloaded.setAt('g', 'zap'), 11);
  });

  test('known names become widgets; only-emoji messages go large', () {
    final sizes = <double>[];
    Widget? builder(String name, double size) {
      if (name != 'zap') return null;
      sizes.add(size);
      return const SizedBox();
    }

    final mixed = emojiSpan('hi :zap: and :nope:', null, builder);
    final children = mixed is TextSpan ? mixed.children! : <InlineSpan>[];
    expect(children.whereType<WidgetSpan>(), hasLength(1));
    expect(mixed.toPlainText(includePlaceholders: false), 'hi  and :nope:');
    expect(sizes.last, lessThan(48));

    emojiSpan(' :zap: ', null, builder);
    expect(sizes.last, 48);
  });
}
