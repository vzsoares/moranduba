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
