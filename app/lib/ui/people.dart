import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// [pubkey]'s profile picture, or the placeholder while it loads.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.session,
    required this.pubkey,
    this.size = 44,
  });

  final Session session;
  final String pubkey;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ref = session.profiles.of(pubkey)?.picture;
    if (ref == null) return Avatar(size: size);
    return FutureBuilder(
      key: ValueKey(ref.url),
      future: session.picture(pubkey),
      builder: (_, snapshot) => Avatar(size: size, picture: snapshot.data),
    );
  }
}

/// [groupId]'s picture, or the group placeholder.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.session,
    required this.groupId,
    this.size = 44,
  });

  final Session session;
  final String groupId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ref = session.groupPictures.of(groupId).picture;
    const icon = Icons.groups_outlined;
    if (ref == null) return Avatar(icon: icon, size: size);
    return FutureBuilder(
      key: ValueKey(ref.url),
      future: session.groupPicture(groupId),
      builder: (_, snapshot) =>
          Avatar(icon: icon, size: size, picture: snapshot.data),
    );
  }
}

/// [pubkey]'s name; monospace when it falls back to a short npub.
class PersonName extends StatelessWidget {
  const PersonName({
    super.key,
    required this.session,
    required this.pubkey,
    this.style,
  });

  final Session session;
  final String pubkey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final named = session.profiles.of(pubkey)?.name.isNotEmpty ?? false;
    return Text(
      session.displayName(pubkey),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: named
          ? style ?? Theme.of(context).textTheme.titleMedium
          : monoStyle,
    );
  }
}

/// Center-crops [bytes] to a [size]px square PNG, so profile pictures stay
/// small whatever the source.
Future<Uint8List> squarePicture(Uint8List bytes, {int size = 256}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final side = math.min(image.width, image.height).toDouble();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(
      (image.width - side) / 2,
      (image.height - side) / 2,
      side,
      side,
    ),
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final square = await recorder.endRecording().toImage(size, size);
  final png = await square.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  square.dispose();
  codec.dispose();
  if (png == null) throw StateError('Could not encode the picture');
  return png.buffer.asUint8List();
}
