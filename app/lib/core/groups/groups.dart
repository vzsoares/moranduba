import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'blossom.dart';
import 'group_engine.dart';
import 'space.dart';

/// Kinds from the Marmot protocol (MIP-00 to MIP-03).
abstract final class MarmotKind {
  static const keyPackage = 30443;
  static const legacyKeyPackage = 443;
  static const welcome = 444;
  static const group = 445;
}

class MissingKeyPackage implements Exception {
  const MissingKeyPackage(this.pubkeys);

  final List<String> pubkeys;

  @override
  String toString() =>
      'MissingKeyPackage: ${pubkeys.length} member(s) have not opened '
      'Moranduba since groups shipped';
}

/// Moves a [GroupEngine]'s events over relays and keeps its state in memory
/// for the UI.
class Groups extends ChangeNotifier {
  Groups({
    required this._ndk,
    required this.me,
    required this._engine,
    required this.relays,
    BlossomClient? blossom,
  }) : _blossom = blossom ?? BlossomClient();

  final String me;
  final List<String> relays;
  final Ndk _ndk;
  final GroupEngine _engine;
  final BlossomClient _blossom;
  final Map<String, Future<Uint8List>> _media = {};
  final _signals = StreamController<GroupSignal>.broadcast();
  final _incoming = StreamController<GroupMessage>.broadcast();

  List<GroupInfo> _groups = [];
  List<GroupInvite> _invites = [];
  final Map<String, List<GroupMessage>> _messages = {};
  StreamSubscription<Nip01Event>? _events;
  String? _subscriptionId;
  Set<String> _subscribed = {};
  final Set<String> _seenEvents = {};

  /// Events that did not decrypt, by id, in arrival order.
  final Map<String, Nip01Event> _failed = {};
  static const _maxFailed = 256;
  Timer? _refreshTimer;
  bool _closed = false;

  /// MLS state must advance in event order, so engine calls are serialized.
  Future<void> _queue = Future.value();

  List<Space> get spaces => [
    for (final g in [
      ..._groups,
    ]..sort((a, b) => (b.lastMessageAt ?? 0).compareTo(a.lastMessageAt ?? 0)))
      Space.fromGroup(g),
  ];

  List<GroupInvite> get invites => List.unmodifiable(_invites);

  GroupInfo? group(String groupId) =>
      _groups.where((g) => g.id == groupId).firstOrNull;

  List<GroupMessage> messagesIn(String groupId) =>
      List.unmodifiable(_messages[groupId] ?? const <GroupMessage>[]);

  /// Chat messages from other members as they arrive, history included.
  Stream<GroupMessage> get incoming => _incoming.stream;

  /// Call signals from other members, as they arrive.
  Stream<GroupSignal> get signals => _signals.stream;

  Future<void> sendSignal(String groupId, String payload) async {
    final info = _require(groupId);
    final event = await _serial(() => _engine.sendSignal(groupId, payload));
    await _publish(_event(event), info.relays);
  }

  /// The call key for [callId] on the group's current epoch.
  Future<ExportedSecret> callKey(String groupId, String callId) => _serial(
    () => _engine.exportSecret(
      groupId,
      label: 'moranduba',
      context: 'call:$callId',
    ),
  );

  Future<List<String>> members(String groupId) =>
      _serial(() => _engine.members(groupId));

  Future<void> start() async {
    await _serial(_refresh);
    await publishKeyPackage();
  }

  Future<void> publishKeyPackage() async {
    final json = await _serial(() => _engine.signedKeyPackage(relays));
    await _publish(_event(json), relays);
  }

  /// Handles a gift wrap that was not a DM. Returns whether it was a welcome.
  Future<bool> onGiftWrap(Nip01Event wrapped) async {
    final Nip01Event rumor;
    try {
      final result = await _ndk.giftWrap.fromGiftWrapWithInfo(
        giftWrap: wrapped,
      );
      if (!result.isCryptographicallyValid) return false;
      rumor = result.rumor;
    } catch (_) {
      return false;
    }
    if (rumor.kind != MarmotKind.welcome) return false;
    try {
      await _serial(() async {
        await _engine.receiveWelcome(wrapped.id, _rumorJson(rumor));
        _invites = await _engine.invites();
      });
    } catch (e) {
      // History replays welcomes we already joined or declined.
      debugPrint('welcome ${wrapped.id}: $e');
      return true;
    }
    _notify();
    return true;
  }

  Future<GroupInfo> create(String name, List<String> members) async {
    final packages = await _keyPackages(members);
    final created = await _serial(
      () => _engine.create(
        name: name,
        relays: relays,
        memberKeyPackages: [for (final p in packages) _json(p)],
      ),
    );
    await _sendWelcomes(created.welcomeRumors, packages);
    await _serial(_refresh);
    return created.group;
  }

  Future<void> addMembers(String groupId, List<String> members) async {
    final info = _require(groupId);
    final packages = await _keyPackages(members);
    final added = await _serial(
      () => _engine.addMembers(groupId, [for (final p in packages) _json(p)]),
    );
    await _publish(_event(added.commit), info.relays);
    await _serial(() => _engine.merge(groupId));
    await _sendWelcomes(added.welcomeRumors, packages);
    await _serial(_refresh);
  }

  Future<void> accept(String inviteId) async {
    await _serial(() async {
      await _engine.acceptInvite(inviteId);
      await _refresh();
    });
    // Joining consumed the key package the inviter used.
    await publishKeyPackage();
  }

  Future<void> decline(String inviteId) => _serial(() async {
    await _engine.declineInvite(inviteId);
    _invites = await _engine.invites();
    _notify();
  });

  /// [expiresAt]: unix seconds, for disappearing messages. [call] sends a
  /// call event (JSON in [text]) instead of a chat message.
  Future<void> send(
    String groupId,
    String text, {
    int? expiresAt,
    bool call = false,
  }) async {
    final info = _require(groupId);
    final event = await _serial(
      () =>
          _engine.encryptText(groupId, text, expiresAt: expiresAt, call: call),
    );
    await _publish(_event(event), info.relays);
    await _serial(() => _reloadGroup(groupId));
  }

  /// Encrypts on device, uploads the ciphertext, then sends the message.
  Future<void> sendFile(
    String groupId,
    Uint8List bytes, {
    required String mime,
    required String filename,
    String caption = '',
    int? expiresAt,
  }) async {
    final info = _require(groupId);
    final encrypted = await _serial(
      () =>
          _engine.encryptMedia(groupId, bytes, mime: mime, filename: filename),
    );
    final url = await _blossom.upload(encrypted.data);
    final event = await _serial(
      () => _engine.sendMedia(
        groupId,
        caption: caption,
        url: url,
        upload: encrypted.upload,
        expiresAt: expiresAt,
      ),
    );
    await _publish(_event(event), info.relays);
    await _serial(() => _reloadGroup(groupId));
  }

  /// The decrypted attachment, fetched once per session.
  Future<Uint8List> media(String groupId, MediaRef ref) =>
      _media[ref.originalHash] ??= () async {
        try {
          final blob = await _blossom.download(ref.url);
          return await _serial(() => _engine.decryptMedia(groupId, blob, ref));
        } catch (_) {
          unawaited(_media.remove(ref.originalHash));
          rethrow;
        }
      }();

  /// Deletes this group's messages created before [before] (unix seconds).
  Future<void> prune(String groupId, int before) async {
    final deleted = await _serial(() => _engine.prune(groupId, before));
    if (deleted == 0) return;
    _messages[groupId]?.removeWhere((m) => m.createdAt < before);
    _notify();
  }

  Future<void> leave(String groupId) async {
    final info = _require(groupId);
    final events = await _serial(() => _engine.leave(groupId));
    for (final event in events) {
      await _publish(_event(event), info.relays);
    }
    await _serial(_refresh);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _refreshTimer?.cancel();
    await _signals.close();
    await _incoming.close();
    await _events?.cancel();
    final id = _subscriptionId;
    if (id != null) await _ndk.requests.closeSubscription(id);
    await _queue;
    await _engine.close();
  }

  /// Leaves no trace of this identity's groups on the device.
  Future<void> wipe() async {
    await close();
    await _engine.wipe();
  }

  GroupInfo _require(String groupId) =>
      group(groupId) ?? (throw StateError('Unknown group $groupId'));

  Future<T> _serial<T>(Future<T> Function() task) {
    final run = _queue.then((_) => task());
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _refresh() async {
    _groups = await _engine.groups();
    _invites = await _engine.invites();
    for (final g in _groups) {
      _messages[g.id] = await _engine.messages(g.id);
    }
    _messages.removeWhere((id, _) => group(id) == null);
    await _resubscribe();
    _notify();
  }

  Future<void> _reloadGroup(String groupId) async {
    _messages[groupId] = await _engine.messages(groupId);
    _groups = await _engine.groups();
    _notify();
  }

  /// Membership and metadata change in bursts while history replays.
  void _refreshSoon() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_serial(_refresh)),
    );
  }

  Future<void> _resubscribe() async {
    final ids = {for (final g in _groups) g.nostrGroupId};
    if (setEquals(ids, _subscribed)) return;
    _subscribed = ids;
    await _events?.cancel();
    final old = _subscriptionId;
    if (old != null) await _ndk.requests.closeSubscription(old);
    _events = null;
    _subscriptionId = null;
    if (ids.isEmpty || _closed) return;

    final response = _ndk.requests.subscription(
      filter: Filter(
        kinds: [MarmotKind.group],
        tags: {
          '#h': [...ids],
        },
      ),
      explicitRelays: {...relays, for (final g in _groups) ...g.relays},
    );
    _subscriptionId = response.requestId;
    _events = response.stream.listen(_onGroupEvent);
  }

  void _onGroupEvent(Nip01Event event) {
    if (!_seenEvents.add(event.id)) return;
    unawaited(_serial(() => _receive(event)));
  }

  Future<void> _receive(Nip01Event event) async {
    try {
      final receipt = await _engine.receive(_json(event));
      final groupId = receipt.groupId;
      final message = receipt.message;
      final commit = receipt.publish;
      final signal = receipt.signal;
      if (signal != null) {
        if (signal.sender != me) _signals.add(signal);
      } else if (message != null) {
        _upsert(message);
        if (message.sender != me) _incoming.add(message);
      } else if (commit != null && groupId != null) {
        final info = group(groupId);
        await _publish(_event(commit), info?.relays ?? relays);
        await _engine.merge(groupId);
        _refreshSoon();
        await _retry(groupId);
      } else if (groupId != null) {
        _refreshSoon();
        await _retry(groupId);
      }
    } catch (e) {
      // Our own events echo back, and replays repeat processed ones.
      debugPrint('group event ${event.id}: $e');
      _failed[event.id] = event;
      if (_failed.length > _maxFailed) _failed.remove(_failed.keys.first);
    }
  }

  /// Feeds back events that came before the commit opening their epoch.
  Future<void> _retry(String groupId) async {
    if (_failed.isEmpty) return;
    for (final id in await _engine.retryable(groupId)) {
      if (_failed.remove(id) case final event?) await _receive(event);
    }
  }

  void _upsert(GroupMessage message) {
    final thread = _messages.putIfAbsent(message.groupId, () => []);
    if (thread.any((m) => m.id == message.id)) return;
    thread
      ..add(message)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _notify();
  }

  /// Each member's newest key package, in [members] order.
  Future<List<Nip01Event>> _keyPackages(List<String> members) async {
    // One request: concurrent queries to a relay sometimes never get EOSE.
    final events = await _ndk.requests
        .query(
          filter: Filter(
            kinds: [MarmotKind.keyPackage, MarmotKind.legacyKeyPackage],
            authors: members,
          ),
          explicitRelays: relays,
          cacheRead: false,
        )
        .future;
    final newest = <String, Nip01Event>{};
    for (final event in events) {
      final known = newest[event.pubKey];
      if (known == null || event.createdAt > known.createdAt) {
        newest[event.pubKey] = event;
      }
    }
    final missing = [
      for (final m in members)
        if (!newest.containsKey(m)) m,
    ];
    if (missing.isNotEmpty) throw MissingKeyPackage(missing);
    return [for (final m in members) ?newest[m]];
  }

  Future<void> _sendWelcomes(
    List<String> rumors,
    List<Nip01Event> keyPackages,
  ) => Future.wait([
    for (final (rumor, package) in pairWelcomes(rumors, keyPackages))
      _sendWelcome(rumor, package),
  ]);

  Future<void> _sendWelcome(String rumorJson, Nip01Event keyPackage) async {
    final wrapped = await _ndk.giftWrap.toGiftWrap(
      rumor: _event(rumorJson),
      recipientPubkey: keyPackage.pubKey,
    );
    await _publish(wrapped, {...keyPackageRelays(keyPackage), ...relays});
  }

  Future<void> _publish(Nip01Event event, Iterable<String> to) async {
    final responses = await _ndk.broadcast
        .broadcast(nostrEvent: event, specificRelays: to)
        .broadcastDoneFuture;
    if (!responses.any((r) => r.broadcastSuccessful)) {
      throw StateError('No relay accepted event ${event.id}');
    }
  }
}

String _json(Nip01Event event) =>
    Nip01EventModel.fromEntity(event).toJsonString();

/// A rumor carries no signature, not even a null one.
String _rumorJson(Nip01Event rumor) =>
    jsonEncode(Nip01EventModel.fromEntity(rumor).toJson()..remove('sig'));

Nip01Event _event(String json) => switch (jsonDecode(json)) {
  final Map<String, Object?> map => Nip01EventModel.fromJson(map),
  _ => throw FormatException('Not an event: $json'),
};

/// Relays a key package asks welcomes to be sent to (its `relays` tag).
List<String> keyPackageRelays(Nip01Event keyPackage) => [
  for (final tag in keyPackage.tags)
    if (tag.isNotEmpty && tag.first == 'relays') ...tag.skip(1),
];

/// Matches each welcome rumor to the key package it was built for, through
/// the rumor's `e` tag. Falls back to list order when tags are missing.
List<(String, Nip01Event)> pairWelcomes(
  List<String> rumors,
  List<Nip01Event> keyPackages,
) {
  final byId = {for (final p in keyPackages) p.id: p};
  return [
    for (var i = 0; i < rumors.length; i++)
      (
        rumors[i],
        _referencedPackage(rumors[i], byId) ??
            (i < keyPackages.length
                ? keyPackages[i]
                : throw StateError('Welcome $i has no matching key package')),
      ),
  ];
}

Nip01Event? _referencedPackage(String rumor, Map<String, Nip01Event> byId) {
  if (jsonDecode(rumor) case {'tags': final List<Object?> tags}) {
    for (final tag in tags) {
      if (tag case ['e', final String id, ...] when byId.containsKey(id)) {
        return byId[id];
      }
    }
  }
  return null;
}
