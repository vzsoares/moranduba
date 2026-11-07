import 'package:ndk/ndk.dart';

/// Control messages ride inside NIP-17 rumors as a `["moranduba", <type>]` tag.
enum Control {
  friendRequest('friend_request'),
  friendAccept('friend_accept'),

  /// Content is the sender's profile JSON.
  profile('profile');

  const Control(this.wire);

  final String wire;

  static const tagName = 'moranduba';

  List<List<String>> get tags => [
    [tagName, wire],
  ];

  static Control? of(Nip01Event rumor) {
    for (final tag in rumor.tags) {
      if (tag.length < 2 || tag[0] != tagName) continue;
      for (final control in values) {
        if (control.wire == tag[1]) return control;
      }
    }
    return null;
  }
}

enum FriendState { none, outgoing, incoming, friend }

/// Derives the friendship state with one peer from their message history,
/// given whether the peer is already in the stored friend list.
FriendState friendStateFrom({
  required bool storedFriend,
  required Iterable<({Control control, bool outgoing})> controls,
}) {
  if (storedFriend) return FriendState.friend;
  var requestedByMe = false;
  var requestedByThem = false;
  for (final c in controls) {
    switch (c.control) {
      case Control.friendAccept:
        return FriendState.friend;
      case Control.friendRequest:
        if (c.outgoing) {
          requestedByMe = true;
        } else {
          requestedByThem = true;
        }
      case Control.profile:
        break;
    }
  }
  if (requestedByMe && requestedByThem) return FriendState.friend;
  if (requestedByThem) return FriendState.incoming;
  if (requestedByMe) return FriendState.outgoing;
  return FriendState.none;
}
