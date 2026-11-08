import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/ui/picture_cropper.dart';

void main() {
  // A 400x200 image fitted into a 100px viewport: 0.5 px per image pixel.
  const side = 100.0;
  const fit = 0.5;
  const child = Size(200, 100);
  final centered = Matrix4.translationValues(-50, 0, 0);

  test('the starting frame is the centered square', () {
    expect(
      visibleSquare(centered, side: side, fit: fit),
      const Rect.fromLTWH(100, 0, 200, 200),
    );
  });

  test('zooming keeps the center and shrinks the frame', () {
    final zoomed = zoomAroundCenter(centered, 2, side: side, child: child);
    expect(
      visibleSquare(zoomed, side: side, fit: fit),
      const Rect.fromLTWH(150, 50, 100, 100),
    );
  });

  test('zooming out never uncovers the viewport', () {
    final corner = Matrix4.diagonal3Values(4, 4, 1)..setTranslationRaw(0, 0, 0);
    final out = zoomAroundCenter(corner, 1, side: side, child: child);
    final frame = visibleSquare(out, side: side, fit: fit);
    expect(frame.left, greaterThanOrEqualTo(0));
    expect(frame.top, greaterThanOrEqualTo(0));
    expect(frame.right, lessThanOrEqualTo(400));
    expect(frame.bottom, lessThanOrEqualTo(200));
  });
}
