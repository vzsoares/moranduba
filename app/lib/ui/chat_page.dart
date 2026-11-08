import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/expiry.dart';
import '../core/groups/media_types.dart';
import '../core/session.dart';
import 'attachments.dart';
import 'composer.dart';
import 'gifs.dart';
import 'expiry_button.dart';
import 'manga.dart';
import 'people.dart';
import 'theme.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.session, required this.peer});

  final Session session;
  final String peer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Row(
            children: [
              PersonAvatar(session: session, pubkey: peer),
              const SizedBox(width: 12),
              Flexible(
                child: PersonName(session: session, pubkey: peer),
              ),
            ],
          ),
        ),
        actions: [
          ListenableBuilder(
            listenable: session,
            builder: (context, _) =>
                ExpiryButton(session: session, chat: dmChat(peer)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) {
                final messages = session.chatWith(peer);
                final pending = session.outbox.inChat(dmChat(peer));
                if (messages.isEmpty && pending.isEmpty) {
                  return const EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'SAY HI',
                    message:
                        'Messages are end-to-end encrypted. Relays only '
                        'see sealed envelopes.',
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  itemCount: pending.length + messages.length,
                  itemBuilder: (context, index) {
                    if (index < pending.length) {
                      return MessageRow(
                        text: pending[pending.length - 1 - index].text,
                        outgoing: true,
                        pending: true,
                      );
                    }
                    index -= pending.length;
                    final m = messages[messages.length - 1 - index];
                    final file = m.fileMetadata;
                    return MessageRow(
                      text: file == null ? m.content : '',
                      outgoing: m.isOutgoing,
                      attachments: [
                        if (file != null)
                          AttachmentView(
                            attachment: Attachment(
                              id: file.originalSha256,
                              filename: dmFileName(m),
                              mime: file.mimeType,
                              load: () => session.dmFile(m),
                              saveGif: session.saveGif,
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          Composer(
            onSend: (text) => session.sendText(peer, text),
            onAttach: _sendAttachment,
            onGif: (bytes, filename) => session.sendFile(
              peer,
              bytes,
              mime: 'image/gif',
              filename: filename,
            ),
            gifs: (send) => GifPanel(session: session, onSend: send),
          ),
        ],
      ),
    );
  }

  Future<void> _sendAttachment() async {
    final file = await openFile();
    if (file == null) return;
    await session.sendFile(
      peer,
      await file.readAsBytes(),
      mime: mimeForFilename(file.name),
      filename: file.name,
    );
  }
}

/// A speech bubble aligned to its side, with an optional speaker label and
/// attachments above it.
class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.text,
    required this.outgoing,
    this.speaker,
    this.attachments = const [],
    this.richText,
    this.pending = false,
  });

  final String text;
  final bool outgoing;

  /// No relay took it yet; the outbox sends it again.
  final bool pending;
  final String? speaker;
  final List<Widget> attachments;
  final InlineSpan Function(TextStyle? style)? richText;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Entrance(
          child: Column(
            crossAxisAlignment: outgoing
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (speaker case final name?)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 4),
                  child: Text(name, style: monoStyle.copyWith(fontSize: 11)),
                ),
              for (final attachment in attachments)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: attachment,
                ),
              if (text.isNotEmpty)
                Opacity(
                  opacity: pending ? .55 : 1,
                  child: SpeechBubble(
                    text: text,
                    outgoing: outgoing,
                    richText: richText,
                  ),
                ),
              if (pending)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.schedule, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        'Waiting for a relay',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
