import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'calls/calls.dart';
import 'expiry.dart';
import 'friend_list.dart';
import 'friend_protocol.dart';
import 'groups/blossom.dart';
import 'groups/group_engine.dart';
import 'groups/groups.dart';
import 'groups/mls_bridge.dart';
import 'groups/mls_platform.dart';
import 'identity.dart';
import 'profiles.dart';
import 'relays.dart';

/// One logged-in identity: relay connection, DM inbox, friendships and
/// groups.
class Session extends ChangeNotifier {
  Session._(
    this.identity,
    this._ndk,
    this._friendList,
    this.relays,
    this.profiles,
    this.expiries,
  );

  /// Groups stay off when [openGroupEngine] is null or fails; see
  /// [groupsError].
  static Future<Session> start(
    Identity identity, {
    List<String>? relays,
    Future<GroupEngine> Function()? openGroupEngine,
    BlossomClient? blossom,
    SnapshotStore? profileStore,
    SnapshotStore? expiryStore,
  }) async {
    final files = blossom ?? BlossomClient();
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
    final book = ProfileBook(
      profileStore ?? await openSnapshotStore('${identity.publicKey}-profiles'),
      files,
    );
    await book.load();
    final timers = ExpiryBook(
      expiryStore ?? await openSnapshotStore('${identity.publicKey}-expiry'),
    );
    await timers.load();
    final session = Session._(
      identity,
      ndk,
      FriendList(ndk, relays: relayList),
      relayList,
      book,
      timers,
    );
    await session._init();
    if (openGroupEngine != null) {
      await session._startGroups(openGroupEngine, files);
    }
    session._shareProfileSoon();
    session._pruneTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(session.pruneExpired()),
    );
    unawaited(session.pruneExpired());
    return session;
  }

  final Identity identity;
  final List<String> relays;
  final ProfileBook profiles;
  final ExpiryBook expiries;
  Timer? _profileTimer;
  Timer? _pruneTimer;
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
      started.signals.listen(_onGroupSignal);
      started.addListener(_shareProfileSoon);
      started.addListener(_announceExpiriesSoon);
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
    switch (Control.of(message.rumor)) {
      case Control.profile when !message.isOutgoing:
        final profile = Profile.decode(message.content);
        if (profile != null &&
            await profiles.put(message.peerPubKey, profile)) {
          notifyListeners();
        }
      case Control.expiry:
        final timer = ChatExpiry.decode(message.content);
        if (timer != null &&
            await expiries.put(dmChat(message.peerPubKey), timer)) {
          unawaited(pruneExpired());
          notifyListeners();
        }
      case _:
    }
    final thread = _messages.putIfAbsent(message.peerPubKey, () => []);
    thread
      ..add(message)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (stateOf(message.peerPubKey) == FriendState.friend &&
        _storedFriends.add(message.peerPubKey)) {
      _scheduleSave();
      _shareProfileSoon();
    }
    notifyListeners();
  }

  Profile? get myProfile => profiles.of(identity.publicKey);

  /// How to show [pubkey] in the UI: their profile name, else a short npub.
  String displayName(String pubkey) {
    final name = profiles.of(pubkey)?.name ?? '';
    if (name.isNotEmpty) return name;
    return pubkey == identity.publicKey ? 'You' : shortKey(pubkey);
  }

  Future<Uint8List?> picture(String pubkey) => profiles.picture(pubkey);

  /// Saves our profile and sends it to every friend and group.
  Future<void> updateProfile({
    required String name,
    Uint8List? picture,
    String? mime,
    bool removePicture = false,
  }) async {
    await profiles.edit(
      identity.publicKey,
      name: name,
      picture: picture,
      mime: mime,
      removePicture: removePicture,
    );
    notifyListeners();
    await _shareProfile();
  }

  void _onGroupSignal(GroupSignal signal) {
    switch (jsonDecode(signal.payload)) {
      case {'t': 'profile', 'profile': final Object? json}:
        final profile = Profile.fromJson(json);
        if (profile == null) return;
        unawaited(
          profiles.put(signal.sender, profile).then((changed) {
            if (changed && !_closed) notifyListeners();
          }),
        );
      case {'t': 'expiry', 'timer': final Object? json}:
        final timer = ChatExpiry.fromJson(json);
        if (timer == null) return;
        unawaited(
          expiries.put(groupChat(signal.groupId), timer).then((changed) async {
            if (!changed) return;
            // They announced it on this epoch already.
            if (groups?.group(signal.groupId)?.epoch case final epoch?) {
              await expiries.markAnnounced(groupChat(signal.groupId), epoch);
            }
            if (!_closed) notifyListeners();
            await pruneExpired();
          }),
        );
    }
  }

  ChatExpiry expiryOf(String chat) => expiries.of(chat);

  /// Sets a chat's disappearing-message timer for everyone in it.
  /// [chat] comes from [dmChat] or [groupChat].
  Future<void> setExpiry(String chat, int seconds) async {
    final now = _now();
    final timer = ChatExpiry(
      seconds: seconds,
      setAt: now > expiries.of(chat).setAt ? now : expiries.of(chat).setAt + 1,
    );
    await expiries.put(chat, timer);
    notifyListeners();
    await _announceExpiry(chat, timer);
    await pruneExpired();
  }

  Future<void> _announceExpiry(String chat, ChatExpiry timer) async {
    final [kind, id] = chat.split(':');
    if (kind == 'dm') {
      await _send(id, jsonEncode(timer.toJson()), Control.expiry.tags);
      return;
    }
    final g = groups;
    if (g == null) return;
    await g.sendSignal(
      id,
      jsonEncode({'t': 'expiry', 'timer': timer.toJson()}),
    );
    if (g.group(id)?.epoch case final epoch?) {
      await expiries.markAnnounced(chat, epoch);
    }
  }

  /// Members who joined since the timer was set learn it on the next epoch.
  void _announceExpiriesSoon() {
    final g = groups;
    if (g == null || _closed) return;
    for (final space in g.spaces) {
      final chat = groupChat(space.id);
      final timer = expiries.of(chat);
      final epoch = g.group(space.id)?.epoch;
      if (timer.setAt == 0 || epoch == null) continue;
      if (expiries.announcedOn(chat, epoch)) continue;
      unawaited(
        expiries
            .markAnnounced(chat, epoch)
            .then((_) => _announceExpiry(chat, timer))
            .catchError((Object e) => debugPrint('announce expiry: $e')),
      );
    }
  }

  /// Unix seconds before which [chat]'s messages are gone, or null.
  int? _cutoff(String chat) {
    final timer = expiries.of(chat);
    return timer.isOn ? _now() - timer.seconds : null;
  }

  int? _expiresAt(String chat) {
    final timer = expiries.of(chat);
    return timer.isOn ? _now() + timer.seconds : null;
  }

  /// Drops expired messages from every chat with a timer.
  Future<void> pruneExpired() async {
    if (_closed) return;
    var changed = false;
    for (final MapEntry(key: chat) in expiries.active.toList()) {
      final cutoff = _cutoff(chat);
      if (cutoff == null) continue;
      final [kind, id] = chat.split(':');
      if (kind == 'group') {
        await groups?.prune(id, cutoff);
      } else {
        final before = _messages[id]?.length ?? 0;
        _messages[id]?.removeWhere(
          (m) => m.createdAt < cutoff && Control.of(m.rumor) == null,
        );
        changed |= (_messages[id]?.length ?? 0) != before;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> sendToGroup(String groupId, String text) =>
      groups!.send(groupId, text, expiresAt: _expiresAt(groupChat(groupId)));

  Future<void> sendFileToGroup(
    String groupId,
    Uint8List bytes, {
    required String mime,
    required String filename,
  }) => groups!.sendFile(
    groupId,
    bytes,
    mime: mime,
    filename: filename,
    expiresAt: _expiresAt(groupChat(groupId)),
  );

  /// Batches profile sends while friends and groups load.
  void _shareProfileSoon() {
    _profileTimer?.cancel();
    _profileTimer = Timer(const Duration(seconds: 2), () {
      unawaited(
        _shareProfile().catchError((Object e) {
          debugPrint('share profile: $e');
        }),
      );
    });
  }

  Future<void> _shareProfile() async {
    final mine = myProfile;
    if (mine == null || _closed) return;
    for (final friend in friends) {
      if (!profiles.needsSending(friend, mine)) continue;
      await _send(friend, mine.encode(), Control.profile.tags);
      await profiles.markSent(friend, mine);
    }
    final g = groups;
    if (g == null) return;
    for (final space in g.spaces) {
      // Keyed by epoch so members who joined since get it too.
      final epoch = g.group(space.id)?.epoch ?? 0;
      final target = 'group:${space.id}@$epoch';
      if (!profiles.needsSending(target, mine)) continue;
      await g.sendSignal(
        space.id,
        jsonEncode({'t': 'profile', 'profile': mine.toJson()}),
      );
      await profiles.markSent(target, mine, replacing: 'group:${space.id}@');
    }
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

  /// Chat messages with [pubkey], oldest first, without control messages
  /// or expired ones.
  List<Nip17Message> chatWith(String pubkey) {
    final cutoff = _cutoff(dmChat(pubkey)) ?? 0;
    return [
      for (final m in _messages[pubkey] ?? const <Nip17Message>[])
        if (Control.of(m.rumor) == null && m.createdAt >= cutoff) m,
    ];
  }

  /// Our profile goes along, so they see who is asking.
  Future<void> requestFriend(String pubkey, {String note = ''}) async {
    if (pubkey == identity.publicKey) {
      throw ArgumentError.value(pubkey, 'pubkey', 'Cannot befriend yourself');
    }
    await _send(
      pubkey,
      note.isEmpty ? 'Wants to be your friend on Moranduba' : note,
      Control.friendRequest.tags,
    );
    if (myProfile case final mine?) {
      await _send(pubkey, mine.encode(), Control.profile.tags);
    }
  }

  Future<void> acceptFriend(String pubkey) async {
    await _send(
      pubkey,
      'Accepted your friend request',
      Control.friendAccept.tags,
    );
    if (_storedFriends.add(pubkey)) _scheduleSave();
    _shareProfileSoon();
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
    return _send(pubkey, text, const [], expiresAt: _expiresAt(dmChat(pubkey)));
  }

  Future<void> _send(
    String pubkey,
    String content,
    List<List<String>> tags, {
    int? expiresAt,
  }) {
    if (expiresAt == null) {
      return _ndk.dms.sendMessage(
        recipientPubKey: pubkey,
        content: content,
        additionalTags: tags,
        recipientDmRelayDiscoveryRelays: relays,
      );
    }
    return _sendExpiring(pubkey, content, tags, expiresAt);
  }

  /// NIP-17 with a NIP-40 tag on the wraps too, which ndk's sendMessage
  /// cannot add, so relays drop the sealed copies when it passes.
  Future<void> _sendExpiring(
    String pubkey,
    String content,
    List<List<String>> tags,
    int expiresAt,
  ) async {
    final expiration = ['expiration', '$expiresAt'];
    final rumor = await _ndk.giftWrap.createRumor(
      content: content,
      kind: Dms.kMessageKind,
      tags: [
        ['p', pubkey],
        ...tags,
        expiration,
      ],
    );
    Future<Nip01Event> wrapFor(String recipient) async => GiftWrap.wrapEvent(
      recipientPublicKey: recipient,
      sealEvent: await _ndk.giftWrap.sealRumor(
        rumor: rumor,
        recipientPubkey: recipient,
      ),
      additionalTags: [expiration],
      eventSignerFactory: _ndk.giftWrap.eventSignerFactory,
      randomizeCreatedAtBefore: rumor.createdAt,
    );
    final theirRelays = await _ndk.userRelayLists.getDmRelays(
      pubkey,
      forceRefresh: true,
      discoveryRelays: relays,
    );
    final sent = await Future.wait([
      _ndk.broadcast
          .broadcast(
            nostrEvent: await wrapFor(pubkey),
            specificRelays: theirRelays ?? relays,
          )
          .broadcastDoneFuture,
      _ndk.broadcast
          .broadcast(
            nostrEvent: await wrapFor(identity.publicKey),
            specificRelays: relays,
          )
          .broadcastDoneFuture,
    ]);
    if (!sent.first.any((r) => r.broadcastSuccessful)) {
      throw StateError('No relay accepted the message');
    }
  }

  /// Batches friend-list writes while history is still streaming in.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => unawaited(_save()));
  }

  Future<void> _save() =>
      _friendList.save(identity.publicKey, {..._storedFriends});

  bool _closed = false;

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Closes the session and deletes this identity's group state.
  Future<void> wipe() async {
    await profiles.wipe();
    await expiries.wipe();
    await calls?.close();
    await groups?.wipe();
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _profileTimer?.cancel();
    _pruneTimer?.cancel();
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
