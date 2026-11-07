import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/groups/media_types.dart';
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
  });

  /// Stable across rebuilds, such as the plaintext hash.
  final String id;
  final String filename;
  final String mime;

  /// Fetches and decrypts; callers cache it.
  final Future<Uint8List> Function() load;
  final int? width;
  final int? height;

  bool get isImage => mime.startsWith('image/');
}

/// A picture preview or a file chip; either opens the viewer.
class AttachmentView extends StatelessWidget {
  const AttachmentView({super.key, required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) => attachment.isImage
      ? _EncryptedImage(key: ValueKey(attachment.id), attachment: attachment)
      : _FileChip(attachment: attachment);
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
    return ConstrainedBox(
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
                      onTap: () =>
                          setState(() => _bytes = widget.attachment.load()),
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
          ),
        ),
      ),
    );
  }
}
