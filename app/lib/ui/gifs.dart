import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/gifs.dart';
import '../core/giphy.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// GIPHY's downsized GIFs stay under this; so do saved ones.
const _maxGifBytes = 8 * 1024 * 1024;

/// The composer's GIF panel: this device's GIFs, and GIPHY search when the
/// build has a key. A picked GIF goes out as an encrypted attachment.
class GifPanel extends StatelessWidget {
  const GifPanel({super.key, required this.session, required this.onSend});

  final Session session;
  final Future<void> Function(Uint8List bytes, String filename) onSend;

  @override
  Widget build(BuildContext context) {
    final mine = _SavedGifs(session: session, onSend: onSend);
    if (!giphyEnabled) return SizedBox(height: 300, child: mine);
    return SizedBox(
      height: 340,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(height: 40, text: 'My GIFs'),
                Tab(height: 40, text: 'GIPHY'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  mine,
                  _GiphySearch(session: session, onSend: onSend),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    if (bytes.length > _maxGifBytes) {
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final gifs = session.gifs.all;
      return LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: _grid(constraints.maxWidth),
          itemCount: gifs.length + 1,
          itemBuilder: (context, index) {
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
            final gif = gifs[index - 1];
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
        tooltip: 'Send · long press to remove',
        onTap: bytes == null
            ? null
            : () => widget.onSend(
                bytes,
                '${widget.gif.sha256.substring(0, 12)}.gif',
              ),
        onLongPress: _remove,
        child: switch ((bytes, snapshot.error)) {
          (final Uint8List bytes, _) => Image.memory(bytes, fit: BoxFit.cover),
          (_, final Object _) => const Icon(Icons.broken_image_outlined),
          _ => const Screentone(child: SizedBox.expand()),
        },
      );
    },
  );
}

class _GiphySearch extends StatefulWidget {
  const _GiphySearch({required this.session, required this.onSend});

  final Session session;
  final Future<void> Function(Uint8List bytes, String filename) onSend;

  @override
  State<_GiphySearch> createState() => _GiphySearchState();
}

class _GiphySearchState extends State<_GiphySearch> {
  final _giphy = Giphy();
  final _query = TextEditingController();
  Timer? _debounce;
  late Future<List<GiphyGif>> _results = _giphy.trending();
  String? _sending;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final query = text.trim();
      setState(
        () =>
            _results = query.isEmpty ? _giphy.trending() : _giphy.search(query),
      );
    });
  }

  /// Downloads first, so the chat never points at GIPHY.
  Future<void> _pick(GiphyGif gif, {required bool save}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = gif.id);
    try {
      final bytes = await _giphy.download(gif);
      if (save) {
        await widget.session.saveGif(bytes);
        messenger.showSnackBar(
          const SnackBar(content: Text('Saved to My GIFs.')),
        );
      } else {
        await widget.onSend(bytes, 'giphy-${gif.id}.gif');
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('GIPHY: $e')));
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: TextField(
          controller: _query,
          onChanged: _search,
          decoration: const InputDecoration(
            hintText: 'Search GIPHY',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
        ),
      ),
      Expanded(
        child: FutureBuilder(
          future: _results,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('GIPHY: ${snapshot.error}'));
            }
            final gifs = snapshot.data;
            if (gifs == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (gifs.isEmpty) return const Center(child: Text('No GIFs.'));
            return LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: _grid(constraints.maxWidth),
                itemCount: gifs.length,
                itemBuilder: (context, index) {
                  final gif = gifs[index];
                  return _Tile(
                    tooltip: 'Send · long press to save',
                    onTap: _sending == null
                        ? () => _pick(gif, save: false)
                        : null,
                    onLongPress: _sending == null
                        ? () => _pick(gif, save: true)
                        : null,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          gif.preview,
                          fit: BoxFit.cover,
                          semanticLabel: gif.title,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image_outlined),
                        ),
                        if (_sending == gif.id)
                          const ColoredBox(
                            color: Color(0x88FFFFFF),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          'Powered by GIPHY · searches go to GIPHY',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.tooltip,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
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
          child: InkWell(onTap: onTap, onLongPress: onLongPress, child: child),
        ),
      ),
    ),
  );
}
