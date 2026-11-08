import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/groups/media_types.dart';
import '../core/calls/call_log.dart';
import '../core/groups/group_engine.dart';
import '../core/expiry.dart';
import '../core/session.dart';
import 'attachments.dart';
import 'chat_page.dart';
import 'composer.dart';
import 'gifs.dart';
import 'emoji.dart';
import 'manga.dart';

/// A group's messages and composer; the chat page and the call page share it.
class GroupConversation extends StatelessWidget {
  const GroupConversation({
    super.key,
    required this.session,
    required this.groupId,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
  });

  final Session session;
  final String groupId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session.groups, session]),
    builder: (context, _) => Column(
      children: [
        Expanded(
          child: _Messages(
            session: session,
            groupId: groupId,
            padding: padding,
          ),
        ),
        Composer(
          onSend: (text) => session.sendToGroup(groupId, text),
          onAttach: _sendAttachment,
          onGif: (bytes, filename) => session.sendFileToGroup(
            groupId,
            bytes,
            mime: 'image/gif',
            filename: filename,
          ),
          gifs: (send) => GifPanel(session: session, onSend: send),
          customEmojis: (insert) => GroupEmojiGrid(
            session: session,
            groupId: groupId,
            onInsert: insert,
          ),
        ),
      ],
    ),
  );

  Future<void> _sendAttachment() async {
    final file = await openFile();
    if (file == null) return;
    await session.sendFileToGroup(
      groupId,
      await file.readAsBytes(),
      mime: mimeForFilename(file.name),
      filename: file.name,
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({
    required this.session,
    required this.groupId,
    required this.padding,
  });

  final Session session;
  final String groupId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final messages = withCallLog(session.groups!.messagesIn(groupId));
    final pending = session.outbox.inChat(groupChat(groupId));
    if (messages.isEmpty && pending.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        title: 'FIRST WORD',
        message:
            'Only members can read this. Each join or leave rolls the '
            'group to new keys.',
      );
    }
    final me = session.identity.publicKey;
    final groups = session.groups!;
    final emoji = groupEmojis(session, groupId);
    return ListView.builder(
      reverse: true,
      padding: padding,
      itemCount: pending.length + messages.length,
      itemBuilder: (context, index) {
        if (index < pending.length) {
          return MessageRow(
            text: pending[pending.length - 1 - index].text,
            outgoing: true,
            pending: true,
          );
        }
        final i = messages.length - 1 - (index - pending.length);
        final m = messages[i];
        if (m is CallLogEntry) return _CallRow(session: session, entry: m);
        if (m is! GroupMessage) return const SizedBox.shrink();
        final previous = i > 0 ? messages[i - 1] : null;
        final outgoing = m.sender == me;
        final followsSame =
            previous is GroupMessage && previous.sender == m.sender;
        return MessageRow(
          text: m.text,
          richText: (style) => emojiSpan(m.text, style, emoji),
          outgoing: outgoing,
          speaker: outgoing || followsSame
              ? null
              : session.displayName(m.sender),
          attachments: [
            for (final media in m.media)
              AttachmentView(
                attachment: Attachment(
                  id: media.originalHash,
                  filename: media.filename,
                  mime: media.mime,
                  width: media.width,
                  height: media.height,
                  load: () => groups.media(groupId, media),
                  saveGif: session.saveGif,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "Alice started a call · 14:02", then the length once it ended.
class _CallRow extends StatelessWidget {
  const _CallRow({required this.session, required this.entry});

  final Session session;
  final CallLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final start = entry.start;
    final at = DateTime.fromMillisecondsSinceEpoch(start.createdAt * 1000);
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final who = start.sender == session.identity.publicKey
        ? 'You'
        : session.displayName(start.sender);
    final text = switch (entry.seconds) {
      final seconds? => 'Call · ${callLength(seconds)} · $who called at $time',
      null => '$who started a call · $time',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Panel(
          toned: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TelephoneIcon(size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(text, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
