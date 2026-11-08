import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/groups/media_types.dart';
import 'files/files.dart';
import 'manga.dart';
import 'media_viewer.dart';
import 'theme.dart';

/// One encrypted attachment, from a group or a DM.
class Attachment {
  const Attachment({
    required this.id,
    required this.filename,
    required this.mime,
    required this.load,
    this.width,
    this.height,
    this.saveGif,
  });

  /// Stable across rebuilds, such as the plaintext hash.
  final String id;
  final String filename;
  final String mime;

  /// Fetches and decrypts; callers cache it.
  final Future<Uint8List> Function() load;
  final int? width;
  final int? height;

  /// Keeps a GIF in My GIFs; the viewer offers it for GIFs when set.
  final Future<void> Function(Uint8List bytes)? saveGif;

  bool get isImage => mime.startsWith('image/');
}

/// A picture or video preview, or a file chip; each opens the viewer.
class AttachmentView extends StatelessWidget {
  const AttachmentView({super.key, required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) => switch (mediaKind(attachment.mime)) {
    MediaKind.image => _EncryptedImage(
      key: ValueKey(attachment.id),
      attachment: attachment,
    ),
    MediaKind.video => _VideoPreview(
      key: ValueKey(attachment.id),
      attachment: attachment,
    ),
    _ => _FileChip(attachment: attachment),
  };
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final kind = mediaKind(attachment.mime);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: RowPanel(
        icon: mediaIcon(kind),
        title: Text(
          attachment.filename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        line: switch (kind) {
          MediaKind.video => 'Video · tap to play',
          MediaKind.audio => 'Audio · tap to play',
          MediaKind.pdf => 'PDF · tap to open',
          _ => 'File · tap to open',
        },
        onTap: () => showMediaViewer(context, attachment),
      ),
    );
  }
}

/// Fetches, decrypts and shows one picture; tap to open, or to retry a failure.
class _EncryptedImage extends StatefulWidget {
  const _EncryptedImage({super.key, required this.attachment});

  final Attachment attachment;

  @override
  State<_EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<_EncryptedImage> {
  late Future<Uint8List> _bytes = widget.attachment.load();

  @override
  Widget build(BuildContext context) {
    final width = widget.attachment.width;
    final height = widget.attachment.height;
    final aspect = width != null && height != null && height > 0
        ? width / height
        : 4 / 3;
    return _framed(
      aspect: aspect,
      child: FutureBuilder(
        future: _bytes,
        builder: (context, snapshot) {
          if (snapshot.data case final bytes?) {
            return GestureDetector(
              onTap: () => showMediaViewer(context, widget.attachment),
              child: MouseRegion(
                cursor: SystemMouseCursors.zoomIn,
                child: Image.memory(bytes, fit: BoxFit.cover),
              ),
            );
          }
          if (snapshot.hasError) {
            return Material(
              color: MangaColors.paper,
              child: InkWell(
                onTap: () => setState(() => _bytes = widget.attachment.load()),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image_outlined),
                      SizedBox(height: 4),
                      Text('Tap to retry'),
                    ],
                  ),
                ),
              ),
            );
          }
          return const Screentone(child: SizedBox.expand());
        },
      ),
    );
  }
}

/// The same frame as a picture: bordered, rounded, at most 320 × 360.
Widget _framed({required double aspect, required Widget child}) =>
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 360),
      child: AspectRatio(
        aspectRatio: aspect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: MangaShape.borderRadius,
            border: Border.all(width: MangaShape.stroke),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              MangaShape.radius - MangaShape.stroke,
            ),
            child: child,
          ),
        ),
      ),
    );

/// Fetches and decrypts a video, then shows its first frame, muted and
/// paused, with its length; tap to play in the viewer. Falls back to the
/// file chip when the platform cannot decode it.
class _VideoPreview extends StatefulWidget {
  const _VideoPreview({super.key, required this.attachment});

  final Attachment attachment;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final media = widget.attachment;
      final controller = await playable(
        await media.load(),
        media.mime,
        media.filename,
      );
      if (!mounted) {
        await disposePlayable(controller);
        return;
      }
      await controller.initialize();
      await controller.setVolume(0);
      // Some decoders paint nothing until the first seek.
      await controller.seekTo(const Duration(milliseconds: 1));
      if (!mounted) {
        await disposePlayable(controller);
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      debugPrint('video preview: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    if (_controller case final controller?) {
      unawaited(disposePlayable(controller));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return _FileChip(attachment: widget.attachment);
    final controller = _controller;
    final width = widget.attachment.width;
    final height = widget.attachment.height;
    final aspect = switch (controller) {
      final c? when c.value.aspectRatio > 0 => c.value.aspectRatio,
      _ when width != null && height != null && height > 0 => width / height,
      _ => 16 / 9,
    };
    if (controller == null) {
      return _framed(
        aspect: aspect,
        child: const Screentone(child: SizedBox.expand()),
      );
    }
    return _framed(
      aspect: aspect,
      child: GestureDetector(
        onTap: () => showMediaViewer(context, widget.attachment),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: MangaColors.ink,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: MangaColors.paper,
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(width: MangaShape.stroke),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.play_arrow, size: 32),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: MangaColors.ink,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      _length(controller.value.duration),
                      style: const TextStyle(
                        color: MangaColors.paper,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _length(Duration d) {
  final minutes = d.inMinutes;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
