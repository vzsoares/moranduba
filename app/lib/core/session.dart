import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'calls/audio_prefs.dart';
import 'calls/call_log.dart';
import 'calls/calls.dart';
import 'calls/host_peer.dart';
import 'calls/sfu_book.dart';
import 'calls/sfu_client.dart';
import 'emojis.dart';
import 'expiry.dart';
import 'friend_list.dart';
import 'dm_archive.dart';
import 'friend_protocol.dart';
import 'gifs.dart';
import 'group_pictures.dart';
import 'groups/blossom.dart';
import 'groups/group_engine.dart';
import 'groups/groups.dart';
import 'groups/mls_bridge.dart';
import 'groups/mls_platform.dart';
import 'groups/space.dart';
import 'hotkeys.dart';
import 'identity.dart';
import 'network.dart';
import 'outbox.dart';
import 'profiles.dart';
import 'push/push.dart';
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
    this.emojis,
    this.groupPictures,
    this.gifs,
    this.dms,
    this.outbox,
    this.audio,
    this.hotkeys,
    this.network,
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
    final network = NetworkBook(
      await openStore('${identity.publicKey}-network'),
    );
    await network.load();
    final files = blossom ?? BlossomClient(servers: network.blossom);
    final relayList = relays ?? network.relays ?? defaultRelays;
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
    final emojiBook = EmojiBook(
      await openStore('${identity.publicKey}-emojis'),
    );
    await emojiBook.load();
    final pictureBook = GroupPictureBook(
      await openStore('${identity.publicKey}-grouppics'),
    );
    await pictureBook.load();
    final gifBook = GifBook(await openStore('${identity.publicKey}-gifs'));
    await gifBook.load();
    final dmArchive = DmArchive(await openStore('${identity.publicKey}-dms'));
    await dmArchive.load();
    final pending = Outbox(await openStore('${identity.publicKey}-outbox'));
    await pending.load();
    final audioPrefs = AudioPrefsBook(
      await openStore('${identity.publicKey}-audio'),
    );
    await audioPrefs.load();
    final hotkeyBook = HotkeyBook(
      await openStore('${identity.publicKey}-hotkeys'),
    );
    await hotkeyBook.load();
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
      emojiBook,
      pictureBook,
      gifBook,
      dmArchive,
      pending,
      audioPrefs,
      hotkeyBook,
      network,
    );
    await session._init();
    if (openGroupEngine != null) {
      await session._startGroups(openGroupEngine, files);
    }
    unawaited(session._flushOutbox());
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
  final EmojiBook emojis;
  final GroupPictureBook groupPictures;
  final GifBook gifs;
  final DmArchive dms;

  /// Text that no relay took yet; sent again in order.
  final Outbox outbox;

  /// Microphone, speaker and voice processing for calls.
  final AudioPrefsBook audio;

  /// Call shortcuts on this device.
  final HotkeyBook hotkeys;

  /// Relays and Blossom servers chosen on this device; they apply on the
  /// next start.
  final NetworkBook network;

  /// Blossom servers attachments go to.
  List<String> get blossomServers => _blossom.servers;
  Timer? _outboxTimer;
  bool _flushing = false;
  final Map<String, Future<Uint8List>> _emojiImages = {};
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

  /// Push stays off until notifications are; then each SFU that our groups
  /// use learns where to ring this device.
  bool _push = false;
  final Set<String> _pushReady = {};
  final Set<String> _pushTrying = {};
  Timer? _pushTimer;
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
    // History first, so it shows even when no relay answers.
    for (final wrapped in dms.wraps) {
      await _onWrapped(wrapped);
    }
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
      // History replays during start; signals heard then are not resent.
      started.signals.listen(_onGroupSignal);
      await started.start();
      groups = started;
      calls = Calls(started, sfuClient: sfuClient)
        ..onCallEvent = (groupId, event) {
          _logCall(groupId, event);
          _pushRing(groupId, event);
        }
        ..serverFor = serverOf
        ..hostsFor = servers.hostsOf
        ..audioPrefs = (() => audio.current);
      started.incoming.listen(_onGroupMessage);
      started.addListener(_shareProfileSoon);
      started.addListener(_announceExpiriesSoon);
      started.addListener(_announceCallLogsSoon);
      started.addListener(_announceEmojisSoon);
      started.addListener(_announceGroupPicturesSoon);
      started.addListener(_announceServersSoon);
      started.addListener(_syncAllowlistsSoon);
      started.addListener(_syncPushSoon);
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
    dms.put(message.id, wrapped);
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
      case {'t': 'sfu', 'sfu': final Object? json} &&
          final Map<String, Object?> body:
        final sfu = PreferredSfu.fromJson(json);
        if (sfu == null) return;
        final hosts = hostPeersFromJson(body['hosts']);
        unawaited(
          Future.wait([
            servers.put(signal.groupId, sfu),
            servers.putHosts(signal.groupId, hosts),
          ]).then((changed) async {
            if (!changed.contains(true)) return;
            if (groups?.group(signal.groupId)?.epoch case final epoch?) {
              await servers.markAnnounced(signal.groupId, epoch);
            }
            _syncAllowlistsSoon();
            _syncPushSoon();
            if (!_closed) notifyListeners();
          }),
        );
      case {'t': 'picture', 'picture': final Object? json}:
        final picture = GroupPicture.fromJson(json);
        if (picture == null) return;
        unawaited(
          groupPictures.put(signal.groupId, picture).then((changed) async {
            if (!changed) return;
            if (groups?.group(signal.groupId)?.epoch case final epoch?) {
              await groupPictures.markAnnounced(signal.groupId, epoch);
            }
            if (!_closed) notifyListeners();
          }),
        );
      case {'t': 'emojis', 'emojis': final List<Object?> list}:
        unawaited(_receiveEmojis(signal.groupId, list));
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

  /// Opted-in host peers of [groupId] (hex pubkeys), newest first.
  List<String> hostsOf(String groupId) => servers.hostsOf(groupId);

  /// Whether this desktop hosts calls for [groupId] right now.
  bool hostsCallsFor(String groupId) => switch (hosting) {
    final sfu? => hostsOf(groupId).contains(sfu.identity.pubkey),
    null => false,
  };

  /// Runs the call server on this desktop and offers it to [groupId] as a
  /// host peer. [dataDir] keeps its key across restarts.
  Future<void> hostCalls(String groupId, {required String dataDir}) async {
    final sfu = hosting ??= await startHostedSfu(
      dataDir: dataDir,
      relays: relays,
    );
    final identity = sfu.identity;
    if (identity.claimCode.isNotEmpty && !ownsServer(identity.pubkey)) {
      await claimServer(identity.pubkey, identity.claimCode);
    }
    await setHost(groupId, identity.pubkey, on: true);
  }

  /// Withdraws this desktop's server from [groupId].
  Future<void> unhostCalls(String groupId) async {
    if (hosting case final sfu?) {
      await setHost(groupId, sfu.identity.pubkey, on: false);
    }
  }

  /// Opts the SFU [pubkey] in or out as a host peer of [groupId], for
  /// everyone in it.
  Future<void> setHost(
    String groupId,
    String pubkey, {
    required bool on,
  }) async {
    final previous = servers.host(groupId, pubkey)?.setAt ?? 0;
    final now = _now();
    await servers.putHosts(groupId, {
      pubkey: HostPeer(on: on, setAt: now > previous ? now : previous + 1),
    });
    notifyListeners();
    await _announceServer(groupId, servers.of(groupId));
    _syncAllowlistsSoon();
    _syncPushSoon();
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
    _syncPushSoon();
  }

  Future<void> _announceServer(String groupId, PreferredSfu choice) async {
    final g = groups;
    if (g == null) return;
    await g.sendSignal(
      groupId,
      jsonEncode({
        't': 'sfu',
        'sfu': choice.toJson(),
        'hosts': servers.hostsJson(groupId),
      }),
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
      final none = choice.setAt == 0 && servers.hostsJson(space.id).isEmpty;
      if (none || epoch == null) continue;
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

  Future<void> _receiveEmojis(String groupId, List<Object?> list) async {
    var changed = false;
    for (final json in list) {
      if (CustomEmoji.fromJson(json) case final emoji?) {
        changed = await emojis.put(groupId, emoji) || changed;
      }
    }
    if (!changed) return;
    if (groups?.group(groupId)?.epoch case final epoch?) {
      await emojis.markAnnounced(groupId, epoch);
    }
    if (!_closed) notifyListeners();
  }

  /// [groupId]'s custom emojis, by name.
  Map<String, PictureRef> emojisOf(String groupId) => emojis.of(groupId);

  /// Uploads [image] encrypted and adds it to [groupId] as `:name:`,
  /// replacing an emoji of that name.
  Future<void> addEmoji(
    String groupId,
    String name,
    Uint8List image, {
    required String mime,
  }) async {
    if (!emojiPattern.hasMatch(':$name:')) {
      throw ArgumentError.value(name, 'name', 'use a-z, 0-9 and _');
    }
    final (sealed, finish) = await encryptPicture(image, mime);
    final picture = finish(await _blossom.upload(sealed));
    await _setEmoji(groupId, name, picture);
  }

  Future<void> removeEmoji(String groupId, String name) =>
      _setEmoji(groupId, name, null);

  Future<void> _setEmoji(
    String groupId,
    String name,
    PictureRef? picture,
  ) async {
    final now = _now();
    final previous = emojis.setAt(groupId, name) ?? 0;
    await emojis.put(
      groupId,
      CustomEmoji(
        name: name,
        picture: picture,
        setAt: now > previous ? now : previous + 1,
      ),
    );
    notifyListeners();
    await _announceEmojis(groupId);
  }

  /// The decrypted image of [picture], fetched once per session.
  /// Keeps [bytes] in this device's GIFs; a GIF already there moves to
  /// the front.
  Future<void> saveGif(Uint8List bytes) async {
    final hash = sha256.convert(bytes).toString();
    final known = gifs.all.where((g) => g.sha256 == hash).firstOrNull;
    if (known != null) {
      await gifs.add(known);
    } else {
      final (sealed, finish) = await encryptPicture(bytes, 'image/gif');
      final picture = finish(await _blossom.upload(sealed));
      await gifs.add(SavedGif(picture: picture, sha256: hash));
    }
    notifyListeners();
  }

  Future<void> forgetGif(SavedGif gif) async {
    await gifs.remove(gif.sha256);
    notifyListeners();
  }

  /// A saved GIF's bytes; shares the emoji picture cache.
  Future<Uint8List> gifImage(SavedGif gif) => emojiImage(gif.picture);

  Future<Uint8List> emojiImage(PictureRef picture) {
    final cached = _emojiImages[picture.url];
    if (cached != null) return cached;
    final loading = _blossom
        .download(picture.url)
        .then((sealed) => decryptPicture(sealed, picture));
    _emojiImages[picture.url] = loading;
    loading.ignore();
    return loading.catchError((Object e) {
      _emojiImages.remove(picture.url);
      throw e;
    });
  }

  Future<void> _announceEmojis(String groupId) async {
    final g = groups;
    final list = emojis.entries(groupId);
    if (g == null || list.isEmpty) return;
    await g.sendSignal(
      groupId,
      jsonEncode({
        't': 'emojis',
        'emojis': [for (final emoji in list) emoji.toJson()],
      }),
    );
    if (g.group(groupId)?.epoch case final epoch?) {
      await emojis.markAnnounced(groupId, epoch);
    }
  }

  /// Members who joined since an emoji changed learn the set on the next
  /// epoch.
  void _announceEmojisSoon() {
    final g = groups;
    if (g == null || _closed) return;
    for (final space in g.spaces) {
      final epoch = g.group(space.id)?.epoch;
      if (epoch == null || emojis.entries(space.id).isEmpty) continue;
      if (emojis.announcedOn(space.id, epoch)) continue;
      unawaited(
        emojis
            .markAnnounced(space.id, epoch)
            .then((_) => _announceEmojis(space.id))
            .catchError((Object e) => debugPrint('announce emojis: $e')),
      );
    }
  }

  /// Saves [prefs] and applies them to the call in progress.
  Future<void> setAudio(AudioPrefs prefs) async {
    await audio.put(prefs);
    await calls?.active?.applyAudio(prefs);
    notifyListeners();
  }

  /// Lets the SFUs of our groups ring this device while the app is closed.
  void enablePush() {
    if (_push || !pushSupported) return;
    _push = true;
    _syncPushSoon();
  }

  /// Every SFU a group of ours uses: its server and its host peers.
  Set<String> _sfusOf(String groupId) => {
    ?serverOf(groupId),
    ...hostsOf(groupId),
  };

  void _syncPushSoon({Duration after = const Duration(seconds: 3)}) {
    if (!_push || _closed) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(after, () {
      unawaited(_syncPush().catchError((Object e) => debugPrint('push: $e')));
    });
  }

  Future<void> _syncPush() async {
    final g = groups;
    if (g == null || _closed) return;
    final sfus = {for (final space in g.spaces) ..._sfusOf(space.id)}
      ..removeAll(_pushReady)
      ..removeAll(_pushTrying);
    _pushTrying.addAll(sfus);
    await Future.wait([
      for (final sfu in sfus)
        _subscribePush(sfu)
            .catchError((Object e) => debugPrint('push via $sfu: $e'))
            .whenComplete(() => _pushTrying.remove(sfu)),
    ]);
  }

  Future<void> _subscribePush(String sfu) async {
    final pong = await pingServer(sfu);
    // The owner's allowlist update may still be on its way.
    if (pong['allowed'] != true) {
      _syncPushSoon(after: const Duration(seconds: 10));
      return;
    }
    final key = pong['push_key'];
    if (key is! String) return;
    final target = await pushSubscribe(sfu, key);
    if (target == null) return;
    await sfuClient.request(sfu, target.toRequest());
    _pushReady.add(sfu);
  }

  /// Asks the group's SFUs to ring the other members' devices when we start
  /// a call, and to stop when it ends.
  void _pushRing(String groupId, CallEvent event) {
    final g = groups;
    final sfus = _sfusOf(groupId);
    if (g == null || _closed || sfus.isEmpty) return;
    unawaited(
      g
          .members(groupId)
          .then((members) async {
            final others = members.where((m) => m != identity.publicKey);
            await Future.wait([
              for (final sfu in sfus)
                sfuClient
                    .request(sfu, {
                      'type': 'ring',
                      'pubkeys': [...others],
                      'call': event.callId,
                      if (event.ended) 'stop': true,
                    })
                    .then<void>((_) {}, onError: (Object _) {}),
            ]);
          })
          .catchError((Object e) => debugPrint('push ring: $e')),
    );
  }

  /// [groupId]'s decrypted picture, or null when it has none.
  Future<Uint8List?> groupPicture(String groupId) {
    final ref = groupPictures.of(groupId).picture;
    return ref == null ? Future.value() : emojiImage(ref);
  }

  /// Uploads [image] encrypted as [groupId]'s picture for everyone; null
  /// removes it.
  Future<void> setGroupPicture(
    String groupId,
    Uint8List? image, {
    String mime = 'image/png',
  }) async {
    PictureRef? ref;
    if (image != null) {
      final (sealed, finish) = await encryptPicture(image, mime);
      ref = finish(await _blossom.upload(sealed));
    }
    final now = _now();
    final previous = groupPictures.of(groupId).setAt;
    final picture = GroupPicture(
      picture: ref,
      setAt: now > previous ? now : previous + 1,
    );
    await groupPictures.put(groupId, picture);
    notifyListeners();
    await _announceGroupPicture(groupId, picture);
  }

  Future<void> _announceGroupPicture(
    String groupId,
    GroupPicture picture,
  ) async {
    final g = groups;
    if (g == null) return;
    await g.sendSignal(
      groupId,
      jsonEncode({'t': 'picture', 'picture': picture.toJson()}),
    );
    if (g.group(groupId)?.epoch case final epoch?) {
      await groupPictures.markAnnounced(groupId, epoch);
    }
  }

  /// Members who joined since the picture changed learn it on the next epoch.
  void _announceGroupPicturesSoon() {
    final g = groups;
    if (g == null || _closed) return;
    for (final space in g.spaces) {
      final picture = groupPictures.of(space.id);
      final epoch = g.group(space.id)?.epoch;
      if (picture.setAt == 0 || epoch == null) continue;
      if (groupPictures.announcedOn(space.id, epoch)) continue;
      unawaited(
        groupPictures
            .markAnnounced(space.id, epoch)
            .then((_) => _announceGroupPicture(space.id, picture))
            .catchError((Object e) => debugPrint('announce picture: $e')),
      );
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
        final expired = [
          for (final m in _messages[id] ?? const <Nip17Message>[])
            if (m.createdAt < cutoff && Control.of(m.rumor) == null) m.id,
        ];
        if (expired.isEmpty) continue;
        _messages[id]?.removeWhere((m) => expired.contains(m.id));
        dms.removeAll(expired);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Queues the text when no relay takes it; see [outbox].
  Future<void> sendToGroup(String groupId, String text) =>
      _sendOrQueue(groupChat(groupId), text);

  Future<void> _sendOrQueue(String chat, String text) async {
    // Behind anything already waiting, so the order holds.
    if (outbox.inChat(chat).isEmpty) {
      try {
        await _deliver(chat, text);
        return;
      } catch (e) {
        debugPrint('queued for later: $e');
      }
    }
    await outbox.add(chat, text);
    notifyListeners();
    _retryOutboxSoon();
  }

  Future<void> _deliver(String chat, String text) {
    final [kind, id] = chat.split(':');
    if (kind == 'group') {
      final g = groups;
      if (g == null) throw StateError('Groups are not up yet');
      return g.send(id, text, expiresAt: _expiresAt(chat));
    }
    return _send(id, text, const [], expiresAt: _expiresAt(chat));
  }

  /// Whether [chat] can still take messages: we left no group, unfriended
  /// nobody.
  bool _reachable(String chat) {
    final [kind, id] = chat.split(':');
    if (kind != 'group') return stateOf(id) == FriendState.friend;
    final g = groups;
    return g == null || g.group(id) != null;
  }

  void _retryOutboxSoon() {
    if (_closed) return;
    _outboxTimer?.cancel();
    _outboxTimer = Timer(
      const Duration(seconds: 20),
      () => unawaited(_flushOutbox()),
    );
  }

  Future<void> _flushOutbox() async {
    if (_flushing || _closed) return;
    _flushing = true;
    try {
      for (final pending in outbox.all) {
        if (_reachable(pending.chat)) {
          try {
            await _deliver(pending.chat, pending.text);
          } catch (e) {
            _retryOutboxSoon();
            return;
          }
        }
        await outbox.remove(pending.id);
        if (!_closed) notifyListeners();
      }
    } finally {
      _flushing = false;
    }
  }

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

  /// Messages containing [query], newest first, from the chats on this
  /// device; only [chat] when given. Nothing leaves the device.
  List<SearchHit> search(String query, {String? chat}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    bool wanted(String key) => chat == null || chat == key;
    final hits = <SearchHit>[
      for (final peer in friends)
        if (wanted(dmChat(peer)))
          for (final m in chatWith(peer))
            if (m.content.toLowerCase().contains(needle))
              SearchHit(
                chat: dmChat(peer),
                sender: m.isOutgoing ? identity.publicKey : peer,
                text: m.content,
                createdAt: m.createdAt,
              ),
      for (final space in groups?.spaces ?? const <Space>[])
        if (wanted(groupChat(space.id)))
          for (final m
              in groups?.messagesIn(space.id) ?? const <GroupMessage>[])
            if (!m.call && m.text.toLowerCase().contains(needle))
              SearchHit(
                chat: groupChat(space.id),
                sender: m.sender,
                text: m.text,
                createdAt: m.createdAt,
              ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return hits;
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

  /// Queues the text when no relay takes it; see [outbox].
  Future<void> sendText(String pubkey, String text) {
    if (stateOf(pubkey) != FriendState.friend) {
      throw StateError('Only friends can be messaged');
    }
    return _sendOrQueue(dmChat(pubkey), text);
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
    await emojis.wipe();
    await groupPictures.wipe();
    await gifs.wipe();
    await dms.wipe();
    await outbox.wipe();
    await audio.wipe();
    await hotkeys.wipe();
    await network.wipe();
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
    _pushTimer?.cancel();
    _outboxTimer?.cancel();
    await _notices.close();
    await calls?.close();
    await sfuClient.close();
    await stopHosting();
    await groups?.close();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _save();
    }
    await dms.close();
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
/// A message that matched a search; [chat] comes from dmChat or groupChat.
class SearchHit {
  const SearchHit({
    required this.chat,
    required this.sender,
    required this.text,
    required this.createdAt,
  });

  final String chat;
  final String sender;
  final String text;

  /// Unix seconds.
  final int createdAt;
}

class Notice {
  const Notice({required this.chat, required this.title, required this.body});

  /// From [dmChat] or [groupChat].
  final String chat;
  final String title;
  final String body;
}
