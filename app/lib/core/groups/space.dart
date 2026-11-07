import 'group_engine.dart';

enum ChannelKind { text, voice }

class Channel {
  const Channel({
    required this.id,
    required this.spaceId,
    required this.kinds,
    required this.mlsGroupId,
  });

  final String id;
  final String spaceId;
  final Set<ChannelKind> kinds;
  final String mlsGroupId;
}

/// A community of channels. In v1 every MLS group is a space with one
/// channel that carries both chat and calls, and the UI hides the space.
class Space {
  const Space({required this.id, required this.name, required this.channels});

  factory Space.fromGroup(GroupInfo group) => Space(
    id: group.id,
    name: group.name,
    channels: [
      Channel(
        id: group.id,
        spaceId: group.id,
        kinds: const {ChannelKind.text, ChannelKind.voice},
        mlsGroupId: group.id,
      ),
    ],
  );

  final String id;
  final String name;
  final List<Channel> channels;

  Channel get main => channels.first;
}
