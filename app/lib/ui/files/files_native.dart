import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// video_player has no Windows or Linux backend of its own.
void setUpMediaPlayback() {
  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux) {
    fvp.registerWith();
  }
}

/// Asks where to save, then writes. Returns false when cancelled.
Future<bool> saveFile(String name, String mime, Uint8List bytes) async {
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return false;
  await File(location.path).writeAsBytes(bytes, flush: true);
  return true;
}

/// A player for decrypted media. The plaintext sits in a temporary file
/// until [disposePlayable] runs.
Future<VideoPlayerController> playable(
  Uint8List bytes,
  String mime,
  String name,
) async {
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/moranduba-${DateTime.now().microsecondsSinceEpoch}-$name',
  );
  await file.writeAsBytes(bytes, flush: true);
  _files[file.path] = file;
  return VideoPlayerController.file(file);
}

final Map<String, File> _files = {};

Future<void> disposePlayable(VideoPlayerController controller) async {
  await controller.dispose();
  final file = _files.remove(controller.dataSource.replaceFirst('file://', ''));
  if (file != null && await file.exists()) await file.delete();
}
