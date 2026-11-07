import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/groups/media_types.dart';
import 'attachments.dart';
import 'files/files.dart';
import 'manga.dart';
import 'theme.dart';

IconData mediaIcon(MediaKind kind) => switch (kind) {
  MediaKind.image => Icons.image_outlined,
  MediaKind.video => Icons.movie_outlined,
  MediaKind.audio => Icons.graphic_eq,
  MediaKind.pdf => Icons.picture_as_pdf_outlined,
  MediaKind.file => Icons.insert_drive_file_outlined,
};

/// Opens an attachment in a centered window with a download button.
Future<void> showMediaViewer(BuildContext context, Attachment media) =>
    showDialog<void>(
      context: context,
      builder: (_) => _MediaViewer(media: media),
    );

class _MediaViewer extends StatefulWidget {
  const _MediaViewer({required this.media});

  final Attachment media;

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final Future<Uint8List> _bytes = widget.media.load();
  bool _saving = false;

  MediaKind get _kind => mediaKind(widget.media.mime);

  Future<void> _download(Uint8List bytes) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await saveFile(
        widget.media.filename,
        widget.media.mime,
        bytes,
      );
      if (saved) {
        messenger.showSnackBar(
          SnackBar(content: Text('Saved ${widget.media.filename}')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final text = Theme.of(context).textTheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 960,
          maxHeight: size.height * .88,
        ),
        child: FutureBuilder(
          future: _bytes,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                  child: Row(
                    children: [
                      Icon(mediaIcon(_kind)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.media.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                      ),
                      if (bytes != null) ...[
                        Text(_formatSize(bytes.length), style: text.bodySmall),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.download, size: 18),
                          label: Text(_saving ? 'Saving…' : 'Download'),
                          onPressed: _saving ? null : () => _download(bytes),
                        ),
                      ],
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: MangaShape.stroke, thickness: 2),
                Flexible(
                  child: switch ((bytes, snapshot.error)) {
                    (final Uint8List bytes, _) => _Preview(
                      kind: _kind,
                      media: widget.media,
                      bytes: bytes,
                    ),
                    (_, final Object error) => Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('Could not load: $error'),
                    ),
                    _ => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Skeleton(width: 240),
                    ),
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _formatSize(int bytes) => switch (bytes) {
  < 1024 => '$bytes B',
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(0)} KB',
  _ => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
};

class _Preview extends StatelessWidget {
  const _Preview({
    required this.kind,
    required this.media,
    required this.bytes,
  });

  final MediaKind kind;
  final Attachment media;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => switch (kind) {
    MediaKind.image => InteractiveViewer(
      maxScale: 6,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      ),
    ),
    MediaKind.video || MediaKind.audio => _Player(
      bytes: bytes,
      media: media,
      audioOnly: kind == MediaKind.audio,
    ),
    MediaKind.pdf || MediaKind.file => Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(mediaIcon(kind), size: 72),
          const SizedBox(height: 12),
          const Text('No preview here. Download it to open.'),
        ],
      ),
    ),
  };
}

class _Player extends StatefulWidget {
  const _Player({
    required this.bytes,
    required this.media,
    required this.audioOnly,
  });

  final Uint8List bytes;
  final Attachment media;
  final bool audioOnly;

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final controller = await playable(
        widget.bytes,
        widget.media.mime,
        widget.media.filename,
      );
      await controller.initialize();
      controller.addListener(_tick);
      if (!mounted) {
        await disposePlayable(controller);
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_tick);
      unawaited(disposePlayable(controller));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_error case final error?) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text('This file does not play here: $error'),
      );
    }
    if (controller == null) {
      return const Padding(padding: EdgeInsets.all(32), child: Skeleton());
    }
    final value = controller.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.audioOnly)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Icon(Icons.graphic_eq, size: 72),
          )
        else
          Flexible(
            child: AspectRatio(
              aspectRatio: value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: value.isPlaying ? 'Pause' : 'Play',
                icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () =>
                    value.isPlaying ? controller.pause() : controller.play(),
              ),
              Expanded(
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: MangaColors.charcoal,
                    bufferedColor: MangaColors.tone,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_clock(value.position)} / ${_clock(value.duration)}',
                style: monoStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
