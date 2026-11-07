import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Message input bar. [onSend] throwing keeps the text for a retry.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, this.onAttach});

  final Future<void> Function(String text) onSend;

  /// Shows an attach button when set.
  final Future<void> Function()? onAttach;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  bool _attaching = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _showError(Object error) {
    final message = 'Not sent: $error';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Copy',
          onPressed: () => Clipboard.setData(ClipboardData(text: message)),
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _input.clear();
      _focus.requestFocus();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach(Future<void> Function() attach) async {
    setState(() => _attaching = true);
    try {
      await attach();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(width: MangaShape.stroke)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        child: Row(
          children: [
            if (widget.onAttach case final attach?) ...[
              IconButton(
                tooltip: 'Send a picture',
                onPressed: _attaching ? null : () => _attach(attach),
                icon: _attaching
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(hintText: 'Message'),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? 'Sending…' : 'Send'),
            ),
          ],
        ),
      ),
    ),
  );
}
