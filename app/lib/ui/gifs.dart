import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/gifs.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// The composer's GIF panel: the GIFs saved on this device. A picked GIF
/// goes out as an encrypted attachment.
class GifPanel extends StatelessWidget {
  const GifPanel({super.key, required this.session, required this.onSend});

  final Session session;
  final Future<void> Function(Uint8List bytes, String filename) onSend;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 300,
    child: _SavedGifs(session: session, onSend: onSend),
  );
}

/// Columns of about [tile] px across whatever width the panel gets.
SliverGridDelegate _grid(double width, {double tile = 120}) =>
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: (width / tile).floor().clamp(2, 8),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
    );

class _SavedGifs extends StatefulWidget {
  const _SavedGifs({required this.session, required this.onSend});

  final Session session;
  final Future<void> Function(Uint8List bytes, String filename) onSend;

  @override
  State<_SavedGifs> createState() => _SavedGifsState();
}

class _SavedGifsState extends State<_SavedGifs> {
  bool _adding = false;

  Session get session => widget.session;

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'GIFs',
          extensions: ['gif'],
          mimeTypes: ['image/gif'],
        ),
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > maxGifBytes) {
      messenger.showSnackBar(
        const SnackBar(content: Text('GIFs must be under 8 MB.')),
      );
      return;
    }
    setState(() => _adding = true);
    try {
      await session.saveGif(bytes);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not saved: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addFromUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    final link = await showDialog<String>(
      context: context,
      builder: (_) => const _UrlDialog(),
    );
    if (link == null || !mounted) return;
    setState(() => _adding = true);
    try {
      await session.saveGif(await fetchGif(link));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not saved: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final gifs = session.gifs.all;
      return LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: _grid(constraints.maxWidth),
          itemCount: gifs.length + 2,
          itemBuilder: (context, index) {
            if (index == 1) {
              return _Tile(
                tooltip: 'Save a GIF from a link',
                onTap: _adding ? null : _addFromUrl,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [Icon(Icons.link), Text('From URL')],
                  ),
                ),
              );
            }
            if (index == 0) {
              return _Tile(
                tooltip: 'Save a GIF from this device',
                onTap: _adding ? null : _add,
                child: Center(
                  child: _adding
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [Icon(Icons.add), Text('Add GIF')],
                        ),
                ),
              );
            }
            final gif = gifs[index - 2];
            return _SavedGifTile(
              key: ValueKey(gif.sha256),
              session: session,
              gif: gif,
              onSend: widget.onSend,
            );
          },
        ),
      );
    },
  );
}

class _SavedGifTile extends StatefulWidget {
  const _SavedGifTile({
    super.key,
    required this.session,
    required this.gif,
    required this.onSend,
  });

  final Session session;
  final SavedGif gif;
  final Future<void> Function(Uint8List bytes, String filename) onSend;

  @override
  State<_SavedGifTile> createState() => _SavedGifTileState();
}

class _SavedGifTileState extends State<_SavedGifTile> {
  late final Future<Uint8List> _bytes = widget.session.gifImage(widget.gif);

  Future<void> _remove() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('REMOVE GIF?'),
        content: const Text('It leaves My GIFs on this device only.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove ?? false) await widget.session.forgetGif(widget.gif);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      return _Tile(
        tooltip: 'Send',
        onTap: bytes == null
            ? null
            : () => widget.onSend(
                bytes,
                '${widget.gif.sha256.substring(0, 12)}.gif',
              ),
        action: (
          icon: Icons.delete_outline,
          tooltip: 'Remove from My GIFs',
          onPressed: _remove,
        ),
        child: switch ((bytes, snapshot.error)) {
          (final Uint8List bytes, _) => Image.memory(bytes, fit: BoxFit.cover),
          (_, final Object _) => const Icon(Icons.broken_image_outlined),
          _ => const Screentone(child: SizedBox.expand()),
        },
      );
    },
  );
}

class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('GIF FROM A LINK'),
    content: SizedBox(
      width: 420,
      child: LabeledField(
        label: 'Link to a .gif',
        hint: 'https://…',
        controller: _link,
        monospace: true,
        autofocus: true,
        onSubmitted: (link) => Navigator.of(context).pop(link),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_link.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// A corner button on a tile: on hover with a mouse, always on touch.
typedef _TileAction = ({
  IconData icon,
  String tooltip,
  VoidCallback? onPressed,
});

bool get _touch => const {
  TargetPlatform.android,
  TargetPlatform.iOS,
}.contains(defaultTargetPlatform);

class _Tile extends StatefulWidget {
  const _Tile({
    required this.tooltip,
    required this.child,
    this.onTap,
    this.action,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onTap;
  final _TileAction? action;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: MangaShape.borderRadius,
          border: Border.all(width: MangaShape.stroke),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            MangaShape.radius - MangaShape.stroke,
          ),
          child: Material(
            color: MangaColors.paper,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Tooltip(
                  message: widget.tooltip,
                  child: InkWell(onTap: widget.onTap, child: widget.child),
                ),
                if (action != null && (_hovered || _touch))
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filled(
                      tooltip: action.tooltip,
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      style: IconButton.styleFrom(
                        backgroundColor: MangaColors.paper,
                        foregroundColor: MangaColors.ink,
                        side: const BorderSide(width: MangaShape.stroke),
                      ),
                      icon: Icon(action.icon),
                      onPressed: action.onPressed,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
