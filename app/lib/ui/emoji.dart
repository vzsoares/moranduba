import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/emojis.dart';
import '../core/groups/media_types.dart';
import '../core/profiles.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// Larger than this and an emoji is a picture, not an emoji.
const _maxEmojiBytes = 512 * 1024;

/// A custom emoji's image, decrypted on first use.
class CustomEmojiImage extends StatelessWidget {
  const CustomEmojiImage({
    super.key,
    required this.session,
    required this.picture,
    this.size = 22,
  });

  final Session session;
  final PictureRef picture;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: FutureBuilder(
      future: session.emojiImage(picture),
      builder: (context, snapshot) => switch (snapshot.data) {
        final bytes? => Image.memory(bytes, fit: BoxFit.contain),
        null => const SizedBox.shrink(),
      },
    ),
  );
}

/// Builds the widget for `:name:`, or null to leave it as text.
typedef EmojiBuilder = Widget? Function(String name, double size);

/// [text] with each known `:name:` drawn by [emoji]. A message that is only
/// emojis shows them large.
InlineSpan emojiSpan(String text, TextStyle? style, EmojiBuilder emoji) {
  final onlyEmojis =
      text.replaceAll(emojiPattern, '').trim().isEmpty &&
      emojiPattern.allMatches(text).every((m) => emoji(m[1]!, 1) != null);
  final size = onlyEmojis ? 48.0 : (style?.fontSize ?? 16) * 1.4;
  final spans = <InlineSpan>[];
  var start = 0;
  for (final match in emojiPattern.allMatches(text)) {
    final widget = emoji(match[1]!, size);
    if (widget == null) continue;
    if (match.start > start) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Tooltip(message: match[0], child: widget),
      ),
    );
    start = match.end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return TextSpan(style: style, children: spans);
}

/// [groupId]'s custom emojis as an [EmojiBuilder].
EmojiBuilder groupEmojis(Session session, String groupId) {
  final emojis = session.emojisOf(groupId);
  return (name, size) => switch (emojis[name]) {
    final picture? => CustomEmojiImage(
      session: session,
      picture: picture,
      size: size,
    ),
    null => null,
  };
}

/// The group tab of the emoji panel: tap to insert, add your own, long-press
/// to remove.
class GroupEmojiGrid extends StatefulWidget {
  const GroupEmojiGrid({
    super.key,
    required this.session,
    required this.groupId,
    required this.onInsert,
  });

  final Session session;
  final String groupId;
  final ValueChanged<String> onInsert;

  @override
  State<GroupEmojiGrid> createState() => _GroupEmojiGridState();
}

class _GroupEmojiGridState extends State<GroupEmojiGrid> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final emojis = widget.session.emojisOf(widget.groupId).entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return GridView.extent(
        padding: const EdgeInsets.all(12),
        maxCrossAxisExtent: 52,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        children: [
          Tooltip(
            message: 'Add an emoji to this group',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _adding ? null : _add,
              child: Center(
                child: _adding
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_reaction_outlined),
              ),
            ),
          ),
          for (final MapEntry(key: name, value: picture) in emojis)
            Tooltip(
              message: ':$name:',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onInsert(':$name: '),
                onLongPress: () => _remove(name),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: CustomEmojiImage(
                    session: widget.session,
                    picture: picture,
                    size: 32,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'gif', 'webp', 'jpg', 'jpeg'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxEmojiBytes) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Emojis must be under 512 KB.')),
      );
      return;
    }
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: emojiName(file.name) ?? ''),
    );
    if (name == null) return;
    setState(() => _adding = true);
    try {
      await widget.session.addEmoji(
        widget.groupId,
        name,
        bytes,
        mime: mimeForFilename(file.name),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not added: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(String name) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('REMOVE :$name:?'),
        content: const Text('It goes away for everyone in this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MangaColors.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await widget.session.removeEmoji(widget.groupId, name);
    }
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => emojiPattern.hasMatch(':${_name.text}:');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('NAME IT'),
    content: LabeledField(
      label: 'Typed as :name:',
      controller: _name,
      hint: 'party_parrot',
      autofocus: true,
      monospace: true,
      maxLength: 32,
      error: _name.text.isEmpty || _valid
          ? null
          : 'Lowercase letters, digits and _',
      onSubmitted: (_) {
        if (_valid) Navigator.of(context).pop(_name.text);
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _valid ? () => Navigator.of(context).pop(_name.text) : null,
        child: const Text('Add'),
      ),
    ],
  );
}
