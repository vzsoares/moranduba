import 'package:flutter/material.dart';

import '../core/session.dart';
import 'theme.dart';

/// Searches the messages on this device: one chat when [chat] is given,
/// else all of them, where tapping a hit calls [onOpen] with its chat.
Future<void> showChatSearch(
  BuildContext context,
  Session session, {
  String? chat,
  ValueChanged<String>? onOpen,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SearchDialog(session: session, chat: chat, onOpen: onOpen),
);

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.session, this.chat, this.onOpen});

  final Session session;
  final String? chat;
  final ValueChanged<String>? onOpen;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _query = TextEditingController();

  /// Long histories stay quick to render.
  static const _shown = 200;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _chatName(String chat) {
    final [kind, id] = chat.split(':');
    final session = widget.session;
    return kind == 'group'
        ? session.groups?.group(id)?.name ?? 'Group'
        : session.displayName(id);
  }

  String _speaker(String pubkey) => pubkey == widget.session.identity.publicKey
      ? 'You'
      : widget.session.displayName(pubkey);

  static String _when(int seconds) {
    final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  /// [text] with each match of [query] in bold.
  static TextSpan _highlighted(String text, String query, TextStyle? style) {
    final needle = query.trim().toLowerCase();
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (needle.isNotEmpty) {
      final at = lower.indexOf(needle, from);
      if (at < 0) break;
      spans
        ..add(TextSpan(text: text.substring(from, at)))
        ..add(
          TextSpan(
            text: text.substring(at, at + needle.length),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              backgroundColor: MangaColors.tone,
            ),
          ),
        );
      from = at + needle.length;
    }
    spans.add(TextSpan(text: text.substring(from)));
    return TextSpan(style: style, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hits = widget.session.search(_query.text, chat: widget.chat);
    return AlertDialog(
      title: Text(
        widget.chat == null ? 'SEARCH ALL CHATS' : 'SEARCH THIS CHAT',
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Words in a message',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 4),
            Text(
              _query.text.trim().isEmpty
                  ? 'Searches only what is on this device.'
                  : '${hits.length} found',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: hits.length.clamp(0, _shown),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final hit = hits[i];
                  final open = widget.onOpen;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      [
                        _speaker(hit.sender),
                        if (widget.chat == null) 'in ${_chatName(hit.chat)}',
                        _when(hit.createdAt),
                      ].join(' · '),
                      style: text.bodySmall,
                    ),
                    subtitle: Text.rich(
                      _highlighted(hit.text, _query.text, text.bodyMedium),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: open == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            open(hit.chat);
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
