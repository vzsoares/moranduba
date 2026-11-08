import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

const _side = 280.0;
const _maxZoom = 6.0;

/// Lets the user drag and zoom [bytes] under a round mask, then returns the
/// framed square as a [size]px PNG; null when cancelled.
Future<Uint8List?> cropPicture(
  BuildContext context,
  Uint8List bytes, {
  int size = 256,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    if (!context.mounted) return null;
    final crop = await showDialog<Rect>(
      context: context,
      builder: (_) => _CropDialog(image: image),
    );
    if (crop == null) return null;
    return await _render(image, crop, size);
  } finally {
    image.dispose();
  }
}

/// The image-pixel square visible through a [side]px viewport, for an image
/// laid out at [fit] px per image pixel and moved by [transform].
@visibleForTesting
Rect visibleSquare(
  Matrix4 transform, {
  required double side,
  required double fit,
}) {
  final scale = transform.getMaxScaleOnAxis() * fit;
  final t = transform.getTranslation();
  return Rect.fromLTWH(-t.x / scale, -t.y / scale, side / scale, side / scale);
}

/// [transform] rescaled to [zoom] around the viewport center, kept so the
/// [child]-sized layer still covers the [side]px viewport.
@visibleForTesting
Matrix4 zoomAroundCenter(
  Matrix4 transform,
  double zoom, {
  required double side,
  required Size child,
}) {
  final old = transform.getMaxScaleOnAxis();
  final t = transform.getTranslation();
  final c = side / 2;
  final tx = (c - (c - t.x) * zoom / old).clamp(side - child.width * zoom, 0.0);
  final ty = (c - (c - t.y) * zoom / old).clamp(
    side - child.height * zoom,
    0.0,
  );
  return Matrix4.diagonal3Values(zoom, zoom, 1)..setTranslationRaw(tx, ty, 0);
}

Future<Uint8List> _render(ui.Image image, Rect src, int size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    src,
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final out = await recorder.endRecording().toImage(size, size);
  try {
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Could not encode the picture');
    return png.buffer.asUint8List();
  } finally {
    out.dispose();
  }
}

class _CropDialog extends StatefulWidget {
  const _CropDialog({required this.image});

  final ui.Image image;

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  final _transform = TransformationController();
  // Own handle: the caller disposes its image while the dialog still fades out.
  late final ui.Image _view = widget.image.clone();
  late final double _fit =
      _side / math.min(widget.image.width, widget.image.height);
  late final Size _child = Size(
    widget.image.width * _fit,
    widget.image.height * _fit,
  );
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    _transform.value = Matrix4.translationValues(
      (_side - _child.width) / 2,
      (_side - _child.height) / 2,
      0,
    );
    _transform.addListener(_syncZoom);
  }

  @override
  void dispose() {
    _transform.dispose();
    _view.dispose();
    super.dispose();
  }

  void _syncZoom() {
    final zoom = _transform.value.getMaxScaleOnAxis();
    if (zoom != _zoom) setState(() => _zoom = zoom);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('FRAME YOUR PICTURE'),
    content: SizedBox(
      width: _side,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox.square(
            dimension: _side,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    minScale: 1,
                    maxScale: _maxZoom,
                    child: SizedBox.fromSize(
                      size: _child,
                      child: RawImage(image: _view, fit: BoxFit.fill),
                    ),
                  ),
                  const IgnorePointer(child: CustomPaint(painter: _Mask())),
                ],
              ),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.zoom_out, size: 20),
              Expanded(
                child: Slider(
                  value: _zoom.clamp(1, _maxZoom),
                  min: 1,
                  max: _maxZoom,
                  onChanged: (zoom) => _transform.value = zoomAroundCenter(
                    _transform.value,
                    zoom,
                    side: _side,
                    child: _child,
                  ),
                ),
              ),
              const Icon(Icons.zoom_in, size: 20),
            ],
          ),
          Text(
            'Drag to move. Pinch, scroll or slide to zoom.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context)
                .pop(visibleSquare(_transform.value, side: _side, fit: _fit)),
        child: const Text('Use picture'),
      ),
    ],
  );
}

class _Mask extends CustomPainter {
  const _Mask();

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final circle = box.deflate(MangaShape.stroke / 2);
    canvas
      ..drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(box)
          ..addOval(circle),
        Paint()..color = MangaColors.paper.withValues(alpha: 0.7),
      )
      ..drawOval(
        circle,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = MangaShape.stroke
          ..color = MangaColors.ink,
      );
  }

  @override
  bool shouldRepaint(_Mask oldDelegate) => false;
}
