import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/session.dart';
import 'composer.dart';
import 'manga.dart';
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
        title: Row(
          children: [
            const Avatar(),
            const SizedBox(width: 12),
            Text(shortKey(peer), style: monoStyle),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) {
                final messages = session.chatWith(peer);
                if (messages.isEmpty) {
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
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[messages.length - 1 - index];
                    return MessageRow(text: m.content, outgoing: m.isOutgoing);
                  },
                );
              },
            ),
          ),
          Composer(onSend: (text) => session.sendText(peer, text)),
        ],
      ),
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
  });

  final String text;
  final bool outgoing;
  final String? speaker;
  final List<Widget> attachments;

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
              if (text.isNotEmpty) SpeechBubble(text: text, outgoing: outgoing),
            ],
          ),
        ),
      ),
    ),
  );
}
