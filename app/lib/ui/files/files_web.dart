import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

void setUpMediaPlayback() {}

/// Hands the bytes to the browser as a download.
Future<bool> saveFile(String name, String mime, Uint8List bytes) async {
  final url = _blobUrl(bytes, mime);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return true;
}

/// A player for decrypted media, read from an in-memory blob URL.
Future<VideoPlayerController> playable(
  Uint8List bytes,
  String mime,
  String name,
) async => VideoPlayerController.networkUrl(Uri.parse(_blobUrl(bytes, mime)));

Future<void> disposePlayable(VideoPlayerController controller) async {
  await controller.dispose();
  web.URL.revokeObjectURL(controller.dataSource);
}

String _blobUrl(Uint8List bytes, String mime) => web.URL.createObjectURL(
  web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)),
);
