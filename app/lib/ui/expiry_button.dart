import 'package:flutter/material.dart';

import '../core/expiry.dart';
import '../core/session.dart';
import 'theme.dart';

/// App bar button for a chat's disappearing-message timer.
class ExpiryButton extends StatelessWidget {
  const ExpiryButton({super.key, required this.session, required this.chat});

  final Session session;

  /// From [dmChat] or [groupChat].
  final String chat;

  @override
  Widget build(BuildContext context) {
    final timer = session.expiryOf(chat);
    final icon = Icon(timer.isOn ? Icons.timer : Icons.timer_outlined);
    final tooltip = 'Disappearing messages: ${expiryLabel(timer.seconds)}';
    void open() => showDialog<void>(
      context: context,
      builder: (_) => _ExpiryDialog(session: session, chat: chat),
    );
    if (!timer.isOn) {
      return IconButton(tooltip: tooltip, icon: icon, onPressed: open);
    }
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        icon: icon,
        label: Text(expiryLabel(timer.seconds)),
        onPressed: open,
      ),
    );
  }
}

class _ExpiryDialog extends StatefulWidget {
  const _ExpiryDialog({required this.session, required this.chat});

  final Session session;
  final String chat;

  @override
  State<_ExpiryDialog> createState() => _ExpiryDialogState();
}

class _ExpiryDialogState extends State<_ExpiryDialog> {
  late int _seconds = widget.session.expiryOf(widget.chat).seconds;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.setExpiry(widget.chat, _seconds);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not set it: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.session.expiryOf(widget.chat).seconds;
    return AlertDialog(
      title: const Text('DISAPPEARING MESSAGES'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'New messages disappear for everyone in this chat after the '
              'time you pick. Older ones go too once they pass it.',
            ),
            const SizedBox(height: 12),
            RadioGroup<int>(
              groupValue: _seconds,
              onChanged: (value) {
                if (value != null && !_saving) setState(() => _seconds = value);
              },
              child: Column(
                children: [
                  for (final seconds in {...expiryChoices, current})
                    RadioListTile<int>(
                      contentPadding: EdgeInsets.zero,
                      value: seconds,
                      title: Text(expiryLabel(seconds)),
                    ),
                ],
              ),
            ),
            if (_error case final error?)
              SelectableText(
                error,
                style: const TextStyle(color: MangaColors.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _seconds == current ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Set'),
        ),
      ],
    );
  }
}
