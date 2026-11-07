import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'calls/call_log.dart';
import 'calls/calls.dart';
import 'calls/host_peer.dart';
import 'calls/sfu_book.dart';
import 'calls/sfu_client.dart';
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
    this._blossom,
    this.servers,
    this.callLogs,
  );

  /// Groups stay off when [openGroupEngine] is null or fails; see
  /// [groupsError].
  static Future<Session> start(
    Identity identity, {
    List<String>? relays,
    Future<GroupEngine> Function()? openGroupEngine,
    BlossomClient? blossom,
    Future<SnapshotStore> Function(String name) openStore = openSnapshotStore,
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
      await openStore('${identity.publicKey}-profiles'),
      files,
    );
    await book.load();
    final timers = ExpiryBook(await openStore('${identity.publicKey}-expiry'));
    await timers.load();
    final sfus = SfuBook(await openStore('${identity.publicKey}-sfu'));
    await sfus.load();
    final logs = CallLogBook(await openStore('${identity.publicKey}-calllog'));
    await logs.load();
    final session = Session._(
      identity,
      ndk,
      FriendList(ndk, relays: relayList),
      relayList,
      book,
      timers,
      files,
      sfus,
      logs,
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
  final BlossomClient _blossom;
  final Map<String, Future<Uint8List>> _dmFiles = {};
  final SfuBook servers;
  final CallLogBook callLogs;
  late final SfuClient sfuClient = SfuClient(
    _ndk,
    me: identity.publicKey,
    relays: relays,
  );

  /// The call server this desktop runs, while hosting.
  HostedSfu? hosting;

  /// Allowlists last sent to the servers we own.
  final Map<String, Set<String>> _allowSent = {};
  Timer? _allowTimer;
  Timer? _profileTimer;
  Timer? _pruneTimer;
  final _notices = StreamController<Notice>.broadcast();

  /// Messages before this are history replaying, not news.
  final int _startedAt = _now() - 30;
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
      calls = Calls(started, sfuClient: sfuClient)
        ..onCallEvent = _logCall
        ..serverFor = (groupId) => switch (servers.of(groupId).pubkey) {
          '' => null,
          final pubkey => pubkey,
        };
      started.signals.listen(_onGroupSignal);
      started.incoming.listen(_onGroupMessage);
      started.addListener(_shareProfileSoon);
      started.addListener(_announceExpiriesSoon);
      started.addListener(_announceCallLogsSoon);
      started.addListener(_announceServersSoon);
      started.addListener(_syncAllowlistsSoon);
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
    if (!message.isOutgoing &&
        message.createdAt >= _startedAt &&
        Control.of(message.rumor) == null) {
      _notices.add(
        Notice(
          chat: dmChat(message.peerPubKey),
          title: displayName(message.peerPubKey),
          body: message.fileMetadata == null
              ? message.content
              : 'Sent ${dmFileName(message)}',
        ),
      );
    }
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

  /// New messages from others, for notifications.
  Stream<Notice> get notices => _notices.stream;

  void _onGroupMessage(GroupMessage message) {
    if (message.createdAt < _startedAt || _closed) return;
    // A call's end is no news; its start is.
    if (message.call && CallEvent.decode(message.text)?.ended != false) return;
    final group = groups?.group(message.groupId)?.name ?? 'Group';
    final body = messagePreview(message);
    _notices.add(
      Notice(
        chat: groupChat(message.groupId),
        title: '${displayName(message.sender)} · $group',
        body: body.isEmpty ? 'Sent a file' : body,
      ),
    );
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
      case {'t': 'sfu', 'sfu': final Object? json}:
        final sfu = PreferredSfu.fromJson(json);
        if (sfu == null) return;
        unawaited(
          servers.put(signal.groupId, sfu).then((changed) async {
            if (!changed) return;
            if (groups?.group(signal.groupId)?.epoch case final epoch?) {
              await servers.markAnnounced(signal.groupId, epoch);
            }
            _syncAllowlistsSoon();
            if (!_closed) notifyListeners();
          }),
        );
      case {'t': 'calllog', 'log': final Object? json}:
        final setting = CallLogSetting.fromJson(json);
        if (setting == null) return;
        unawaited(
          callLogs.put(signal.groupId, setting).then((changed) async {
            if (!changed) return;
            if (groups?.group(signal.groupId)?.epoch case final epoch?) {
              await callLogs.markAnnounced(signal.groupId, epoch);
            }
            if (!_closed) notifyListeners();
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

  /// The group's call server pubkey (hex), or null for mesh calls.
  String? serverOf(String groupId) => switch (servers.of(groupId).pubkey) {
    '' => null,
    final pubkey => pubkey,
  };

  /// Whether [pubkey] is a call server we claimed.
  bool ownsServer(String pubkey) => servers.owned.contains(pubkey);

  /// Checks [sfu] answers; returns its `pong`.
  Future<Map<String, Object?>> pingServer(String sfu) =>
      sfuClient.request(sfu, {'type': 'ping'});

  /// Becomes the owner of a fresh server with the code it printed.
  Future<void> claimServer(String sfu, String code) async {
    await sfuClient.request(sfu, {'type': 'claim', 'code': code.trim()});
    await servers.own(sfu);
    _syncAllowlistsSoon();
  }

  /// Runs the call server on this desktop (host peer) and makes it
  /// [groupId]'s server. [dataDir] keeps its key across restarts.
  Future<void> hostCalls(String groupId, {required String dataDir}) async {
    final sfu = hosting ??= await startHostedSfu(
      dataDir: dataDir,
      relays: relays,
    );
    final identity = sfu.identity;
    if (identity.claimCode.isNotEmpty && !ownsServer(identity.pubkey)) {
      await claimServer(identity.pubkey, identity.claimCode);
    }
    await setServer(groupId, identity.pubkey);
  }

  Future<void> stopHosting() async {
    final sfu = hosting;
    hosting = null;
    await sfu?.stop();
    notifyListeners();
  }

  /// Sets [groupId]'s call server for everyone in it; null goes back to mesh.
  Future<void> setServer(String groupId, String? sfu) async {
    final previous = servers.of(groupId).setAt;
    final now = _now();
    final choice = PreferredSfu(
      pubkey: sfu ?? '',
      setAt: now > previous ? now : previous + 1,
    );
    await servers.put(groupId, choice);
    notifyListeners();
    await _announceServer(groupId, choice);
    _syncAllowlistsSoon();
  }

  Future<void> _announceServer(String groupId, PreferredSfu choice) async {
    final g = groups;
    if (g == null) return;
    await g.sendSignal(
      groupId,
      jsonEncode({'t': 'sfu', 'sfu': choice.toJson()}),
    );
    if (g.group(groupId)?.epoch case final epoch?) {
      await servers.markAnnounced(groupId, epoch);
    }
  }

  void _announceServersSoon() {
    final g = groups;
    if (g == null || _closed) return;
    for (final space in g.spaces) {
      final choice = servers.of(space.id);
      final epoch = g.group(space.id)?.epoch;
      if (choice.setAt == 0 || epoch == null) continue;
      if (servers.announcedOn(space.id, epoch)) continue;
      unawaited(
        servers
            .markAnnounced(space.id, epoch)
            .then((_) => _announceServer(space.id, choice))
            .catchError((Object e) => debugPrint('announce server: $e')),
      );
    }
  }

  /// Membership settles in bursts; one allowlist update per server after.
  void _syncAllowlistsSoon() {
    _allowTimer?.cancel();
    _allowTimer = Timer(const Duration(seconds: 2), () {
      unawaited(
        _syncAllowlists().catchError((Object e) {
          debugPrint('sync allowlists: $e');
        }),
      );
    });
  }

  /// Keeps each owned server's allowlist equal to the members of the
  /// groups that use it.
  Future<void> _syncAllowlists() async {
    final g = groups;
    if (g == null || _closed) return;
    for (final sfu in servers.owned) {
      final members = <String>{identity.publicKey};
      for (final groupId in servers.groupsOn(sfu)) {
        if (g.group(groupId) == null) continue;
        members.addAll(await g.members(groupId));
      }
      if (setEquals(_allowSent[sfu], members)) continue;
      await sfuClient.request(sfu, {
        'type': 'allow',
        'pubkeys': [...members],
      });
      _allowSent[sfu] = members;
    }
  }

  /// Whether [groupId] records calls in its chat.
  bool logsCalls(String groupId) => callLogs.of(groupId).on;

  /// Turns the call log on or off for everyone in [groupId].
  Future<void> setCallLog(String groupId, {required bool on}) async {
    final now = _now();
    final previous = callLogs.of(groupId).setAt;
    final setting = CallLogSetting(
      on: on,
      setAt: now > previous ? now : previous + 1,
    );
    await callLogs.put(groupId, setting);
    notifyListeners();
    await _announceCallLog(groupId, setting);
  }

  Future<void> _announceCallLog(String groupId, CallLogSetting setting) async {
    final g = groups;
    if (g == null) return;
    await g.sendSignal(
      groupId,
      jsonEncode({'t': 'calllog', 'log': setting.toJson()}),
    );
    if (g.group(groupId)?.epoch case final epoch?) {
      await callLogs.markAnnounced(groupId, epoch);
    }
  }

  /// Members who joined since the setting changed learn it on the next epoch.
  void _announceCallLogsSoon() {
    final g = groups;
    if (g == null || _closed) return;
    for (final space in g.spaces) {
      final setting = callLogs.of(space.id);
      final epoch = g.group(space.id)?.epoch;
      if (setting.setAt == 0 || epoch == null) continue;
      if (callLogs.announcedOn(space.id, epoch)) continue;
      unawaited(
        callLogs
            .markAnnounced(space.id, epoch)
            .then((_) => _announceCallLog(space.id, setting))
            .catchError((Object e) => debugPrint('announce call log: $e')),
      );
    }
  }

  void _logCall(String groupId, CallEvent event) {
    final g = groups;
    if (g == null || _closed || !logsCalls(groupId)) return;
    unawaited(
      g
          .send(
            groupId,
            event.encode(),
            call: true,
            expiresAt: _expiresAt(groupChat(groupId)),
          )
          .catchError((Object e) => debugPrint('log call: $e')),
    );
  }

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

  /// Encrypts on device (NIP-17 kind 15), uploads the ciphertext, then
  /// sends the key inside the gift wrap.
  Future<void> sendFile(
    String pubkey,
    Uint8List bytes, {
    required String mime,
    required String filename,
  }) async {
    if (stateOf(pubkey) != FriendState.friend) {
      throw StateError('Only friends can be messaged');
    }
    final encrypted = await Nip17FileCrypto.encrypt(bytes);
    final url = await _blossom.upload(encrypted.ciphertext);
    final metadata = Nip17FileMetadata.fromEncryptedFile(
      url: Uri.parse(url),
      mimeType: mime,
      encryptedFile: encrypted,
    );
    final name = ['name', filename];
    final expiresAt = _expiresAt(dmChat(pubkey));
    if (expiresAt == null) {
      await _ndk.dms.sendFileMessage(
        recipientPubKey: pubkey,
        metadata: metadata,
        additionalTags: [name],
        recipientDmRelayDiscoveryRelays: relays,
      );
      return;
    }
    await _sendExpiring(
      pubkey,
      url,
      [...metadata.toTags(), name],
      expiresAt,
      kind: Dms.kFileMessageKind,
    );
  }

  /// The decrypted file of a kind-15 message, fetched once per session.
  Future<Uint8List> dmFile(Nip17Message message) =>
      _dmFiles[message.id] ??= () async {
        try {
          final metadata =
              message.fileMetadata ??
              (throw const FormatException('Not a file message'));
          return await Nip17FileCrypto.decrypt(
            ciphertext: await _blossom.download(metadata.url.toString()),
            metadata: metadata,
          );
        } catch (_) {
          _dmFiles.remove(message.id)?.ignore();
          rethrow;
        }
      }();

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
    int expiresAt, {
    int kind = Dms.kMessageKind,
  }) async {
    final expiration = ['expiration', '$expiresAt'];
    final rumor = await _ndk.giftWrap.createRumor(
      content: content,
      kind: kind,
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
    await servers.wipe();
    await callLogs.wipe();
    await calls?.close();
    await groups?.wipe();
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _profileTimer?.cancel();
    _pruneTimer?.cancel();
    _allowTimer?.cancel();
    await _notices.close();
    await calls?.close();
    await sfuClient.close();
    await stopHosting();
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

/// The filename a kind-15 DM carries in its `name` tag.
String dmFileName(Nip17Message message) {
  for (final tag in message.rumor.tags) {
    if (tag case ['name', final String name] when name.isNotEmpty) return name;
  }
  return 'file';
}

/// A new message worth telling the user about.
class Notice {
  const Notice({required this.chat, required this.title, required this.body});

  /// From [dmChat] or [groupChat].
  final String chat;
  final String title;
  final String body;
}
