import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../core/sounds.dart';

void primeTones() {}

final Map<Tone, Future<VideoPlayerController>> _players = {};

/// Plays [tone] from a rendered WAV; the system alert if that fails.
Future<void> playTone(Tone tone) async {
  try {
    final player = await (_players[tone] ??= _open(tone));
    await player.seekTo(Duration.zero);
    await player.play();
  } catch (e) {
    debugPrint('tone ${tone.name}: $e');
    _players.remove(tone)?.ignore();
    await SystemSound.play(SystemSoundType.alert);
  }
}

Future<VideoPlayerController> _open(Tone tone) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/moranduba-tone-${tone.name}.wav');
  await file.writeAsBytes(renderWav(tone), flush: true);
  final player = VideoPlayerController.file(
    file,
    videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
  );
  await player.initialize();
  return player;
}
