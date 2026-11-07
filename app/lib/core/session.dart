import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'calls/calls.dart';
import 'friend_list.dart';
import 'groups/blossom.dart';
import 'groups/group_engine.dart';
import 'groups/groups.dart';
import 'friend_protocol.dart';
import 'identity.dart';
import 'relays.dart';

/// One logged-in identity: relay connection, DM inbox, friendships and
/// groups.
class Session extends ChangeNotifier {
  Session._(this.identity, this._ndk, this._friendList, this.relays);

  /// Groups stay off when [openGroupEngine] is null or fails; see
  /// [groupsError].
  static Future<Session> start(
    Identity identity, {
    List<String>? relays,
    Future<GroupEngine> Function()? openGroupEngine,
    BlossomClient? blossom,
  }) async {
    final relayList = relays ?? defaultRelays;
    final ndk = Ndk(
      NdkConfig(
        cache: MemCacheManager(),
        eventVerifier: Bip340EventVerifier(),
        bootstrapRelays: relayList,
      ),
    );
    ndk.accounts.loginPrivateKey(
      pubkey: identity.publicKey,
      privkey: identity.privateKey,
    );
    final session = Session._(
      identity,
      ndk,
      FriendList(ndk, relays: relayList),
      relayList,
    );
    await session._init();
    if (openGroupEngine != null) {
      await session._startGroups(openGroupEngine, blossom);
    }
    return session;
  }

  final Identity identity;
  final List<String> relays;
  Groups? groups;
  Calls? calls;
  Object? groupsError;
  final Ndk _ndk;
  final FriendList _friendList;

  final Map<String, List<Nip17Message>> _messages = {};
  final Set<String> _seen = {};
  final Set<String> _declined = {};
  final List<Nip01Event> _unhandledWraps = [];
  Set<String> _storedFriends = {};
  StreamSubscription<Nip01Event>? _inbox;
  String? _subscriptionId;
  Timer? _saveTimer;

  Future<void> _init() async {
    // Senders discover where to deliver gift wraps from this kind 10050 list.
    await _ndk.dms.publishDmRelays(
      relayUrlsOrdered: relays,
      broadcastRelays: relays,
    );
    _storedFriends = await _friendList.load();
    final response = _ndk.requests.subscription(
      filter: Filter(
        kinds: [GiftWrap.kGiftWrapEventkind],
        pTags: [identity.publicKey],
      ),
      explicitRelays: relays,
    );
    _subscriptionId = response.requestId;
    _inbox = response.stream.listen(_onWrapped);
  }

  Future<void> _startGroups(
    Future<GroupEngine> Function() open,
    BlossomClient? blossom,
  ) async {
    try {
      final started = Groups(
        ndk: _ndk,
        me: identity.publicKey,
        engine: await open(),
        relays: relays,
        blossom: blossom,
      );
      await started.start();
      groups = started;
      calls = Calls(started);
      // Welcomes that arrived before groups were up.
      for (final wrapped in _unhandledWraps) {
        await started.onGiftWrap(wrapped);
      }
    } catch (e) {
      groupsError = e;
    }
    _unhandledWraps.clear();
    notifyListeners();
  }

  Future<void> _onWrapped(Nip01Event wrapped) async {
    final message = await _ndk.dms.parseWrappedMessage(wrappedEvent: wrapped);
    if (message == null) {
      final g = groups;
      if (g != null) {
        await g.onGiftWrap(wrapped);
      } else if (groupsError == null) {
        _unhandledWraps.add(wrapped);
      }
      return;
    }
    if (!_seen.add(message.id)) return;
    final thread = _messages.putIfAbsent(message.peerPubKey, () => []);
    thread
      ..add(message)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (stateOf(message.peerPubKey) == FriendState.friend &&
        _storedFriends.add(message.peerPubKey)) {
      _scheduleSave();
    }
    notifyListeners();
  }

  FriendState stateOf(String pubkey) => friendStateFrom(
    storedFriend: _storedFriends.contains(pubkey),
    controls: [
      for (final m in _messages[pubkey] ?? const <Nip17Message>[])
        if (Control.of(m.rumor) case final control?)
          (control: control, outgoing: m.isOutgoing),
    ],
  );

  List<String> get friends => _peersIn(FriendState.friend);

  List<String> get incomingRequests =>
      _peersIn(FriendState.incoming)
          .where((pubkey) => !_declined.contains(pubkey))
          .toList();

  List<String> get outgoingRequests => _peersIn(FriendState.outgoing);

  List<String> _peersIn(FriendState state) => {
    ..._storedFriends,
    ..._messages.keys,
  }.where((pubkey) => stateOf(pubkey) == state).toList();

  /// Chat messages with [pubkey], oldest first, without control messages.
  List<Nip17Message> chatWith(String pubkey) => [
    for (final m in _messages[pubkey] ?? const <Nip17Message>[])
      if (Control.of(m.rumor) == null) m,
  ];

  Future<void> requestFriend(String pubkey, {String note = ''}) {
    if (pubkey == identity.publicKey) {
      throw ArgumentError.value(pubkey, 'pubkey', 'Cannot befriend yourself');
    }
    return _send(
      pubkey,
      note.isEmpty ? 'Wants to be your friend on Moranduba' : note,
      Control.friendRequest.tags,
    );
  }

  Future<void> acceptFriend(String pubkey) async {
    await _send(
      pubkey,
      'Accepted your friend request',
      Control.friendAccept.tags,
    );
    if (_storedFriends.add(pubkey)) _scheduleSave();
    notifyListeners();
  }

  void declineFriend(String pubkey) {
    _declined.add(pubkey);
    notifyListeners();
  }

  Future<void> sendText(String pubkey, String text) {
    if (stateOf(pubkey) != FriendState.friend) {
      throw StateError('Only friends can be messaged');
    }
    return _send(pubkey, text, const []);
  }

  Future<void> _send(String pubkey, String content, List<List<String>> tags) =>
      _ndk.dms.sendMessage(
        recipientPubKey: pubkey,
        content: content,
        additionalTags: tags,
        recipientDmRelayDiscoveryRelays: relays,
      );

  /// Batches friend-list writes while history is still streaming in.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => unawaited(_save()));
  }

  Future<void> _save() =>
      _friendList.save(identity.publicKey, {..._storedFriends});

  bool _closed = false;

  /// Closes the session and deletes this identity's group state.
  Future<void> wipe() async {
    await calls?.close();
    await groups?.wipe();
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await calls?.close();
    await groups?.close();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _save();
    }
    await _inbox?.cancel();
    final id = _subscriptionId;
    if (id != null) await _ndk.requests.closeSubscription(id);
    await _ndk.destroy();
  }
}
