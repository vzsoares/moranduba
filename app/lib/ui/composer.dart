import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Message input bar. [onSend] throwing keeps the text for a retry.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.onAttach,
    this.customEmojis,
    this.onGif,
    this.gifs,
  });

  final Future<void> Function(String text) onSend;

  /// Shows an attach button when set.
  final Future<void> Function()? onAttach;

  /// A second emoji tab (the group's own), given a way to insert text.
  final Widget Function(ValueChanged<String> insert)? customEmojis;

  /// Sends a picked GIF; with [gifs], shows a GIF button.
  final Future<void> Function(Uint8List bytes, String filename)? onGif;

  /// The GIF panel, given how to send a pick.
  final Widget Function(
    Future<void> Function(Uint8List bytes, String filename) send,
  )?
  gifs;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  bool _attaching = false;
  bool _emojis = false;
  bool _gifs = false;

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

  /// Puts [text] at the cursor, replacing any selection.
  void _insert(String text) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _input.value = value.copyWith(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  Widget _emojiPanel() {
    final picker = LayoutBuilder(
      builder: (context, constraints) => EmojiPicker(
        textEditingController: _input,
        config: Config(
          height: 280,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            backgroundColor: MangaColors.paper,
            // About 48 px per emoji, whatever the window width.
            columns: (constraints.maxWidth / 48).floor().clamp(7, 24),
            emojiSizeMax: 26,
          ),
          categoryViewConfig: const CategoryViewConfig(
            backgroundColor: MangaColors.paper,
            indicatorColor: MangaColors.ink,
            iconColorSelected: MangaColors.ink,
          ),
          bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
          searchViewConfig: const SearchViewConfig(
            backgroundColor: MangaColors.paper,
          ),
        ),
      ),
    );
    final custom = widget.customEmojis;
    if (custom == null) return SizedBox(height: 280, child: picker);
    return SizedBox(
      height: 320,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(height: 40, text: 'Emoji'),
                Tab(height: 40, text: 'Group'),
              ],
            ),
            Expanded(child: TabBarView(children: [picker, custom(_insert)])),
          ],
        ),
      ),
    );
  }

  Future<void> _sendGif(Uint8List bytes, String filename) async {
    final send = widget.onGif;
    if (send == null) return;
    setState(() => _gifs = false);
    try {
      await send(bytes, filename);
    } catch (e) {
      if (mounted) _showError(e);
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_emojis) _emojiPanel(),
          if (_gifs) ?widget.gifs?.call(_sendGif),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: _emojis ? 'Close emojis' : 'Emojis',
                  isSelected: _emojis,
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  selectedIcon: const Icon(Icons.emoji_emotions),
                  onPressed: () => setState(() {
                    _emojis = !_emojis;
                    _gifs = false;
                  }),
                ),
                if (widget.gifs != null && widget.onGif != null)
                  IconButton(
                    tooltip: _gifs ? 'Close GIFs' : 'GIFs',
                    isSelected: _gifs,
                    icon: const Icon(Icons.gif_box_outlined),
                    selectedIcon: const Icon(Icons.gif_box),
                    onPressed: () => setState(() {
                      _gifs = !_gifs;
                      _emojis = false;
                    }),
                  ),
                if (widget.onAttach case final attach?) ...[
                  IconButton(
                    tooltip: 'Attach a file',
                    onPressed: _attaching ? null : () => _attach(attach),
                    icon: _attaching
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file),
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
        ],
      ),
    ),
  );
}
