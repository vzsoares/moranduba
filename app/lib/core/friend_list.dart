import 'package:ndk/ndk.dart';

/// Friend list stored as a NIP-51 follow set whose entries are all
/// NIP-44-encrypted, so relays only see that the set exists.
class FriendList {
  FriendList(this._ndk, {required this.relays});

  static const setName = 'moranduba-friends';

  final Ndk _ndk;
  final List<String> relays;

  Future<Set<String>> load() async {
    final set = await _ndk.lists.getSetByName(
      name: setName,
      kind: Nip51List.kFollowSet,
      forceRefresh: true,
    );
    if (set == null) return {};
    return {
      for (final e in set.elements)
        if (e.tag == Nip51List.kPubkey) e.value,
    };
  }

  /// Replaces the whole set. `Lists.addElementToSet` creates new sets with
  /// the relay-set kind, so the set is always written complete.
  Future<void> save(String ownerPubkey, Set<String> friends) async {
    final set = Nip51Set(
      pubKey: ownerPubkey,
      name: setName,
      kind: Nip51List.kFollowSet,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      elements: [
        for (final pubkey in friends)
          Nip51ListElement(
            tag: Nip51List.kPubkey,
            value: pubkey,
            private: true,
          ),
      ],
    );
    await _ndk.lists.setCompleteSet(
      set: set,
      kind: Nip51List.kFollowSet,
      specificRelays: relays,
    );
  }
}
