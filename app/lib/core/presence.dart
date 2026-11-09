import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ndk/ndk.dart';

import 'groups/mls_bridge.dart';
import 'publish.dart';

/// Ephemeral, so relays forward pings and store none.
const presenceKind = 21060;

/// Pings rotate their tag this often, so a relay cannot follow one key
/// across windows.
const presenceWindow = Duration(minutes: 10);

/// The tag a ping carries in the window containing [at]; only holders of
/// [key] can compute it.
String presenceTag(String key, DateTime at) {
  final window = at.millisecondsSinceEpoch ~/ presenceWindow.inMilliseconds;
  final mac = Hmac(sha256, utf8.encode(key));
  return mac
      .convert(utf8.encode('moranduba-presence:$window'))
      .toString()
      .substring(0, 32);
}

/// A friend's presence key and the relays they ping on.
class PresenceKey {
  const PresenceKey(this.key, this.relays);

  final String key;
  final List<String> relays;

  String encode() => jsonEncode({'key': key, 'relays': relays});

  static PresenceKey? decode(String content) {
    try {
      return switch (jsonDecode(content)) {
        {'key': final String key, 'relays': final List<Object?> relays}
            when key.length == 64 =>
          PresenceKey(key, relays.whereType<String>().toList()),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

/// What a ping says besides "online".
enum Beat {
  alive(''),

  /// Asks friends who see it to ping back.
  hello('hello'),

  /// Going hidden: friends drop the dot at once instead of after
  /// [Presence.fresh].
  bye('bye');

  const Beat(this.content);

  final String content;

  static Beat of(String content) =>
      values.where((b) => b.content == content).firstOrNull ?? alive;
}

/// Our presence key, who has it, and the friends' keys we hold.
class PresenceBook {
  PresenceBook(this._store);

  final SnapshotStore _store;
  String _mine = '';
  bool _hidden = false;
  final Map<String, String> _sent = {};
  final Map<String, PresenceKey> _theirs = {};

  String get mine => _mine;
  Map<String, PresenceKey> get theirs => Map.unmodifiable(_theirs);
  bool get sharedWithAnyone => _sent.isNotEmpty;

  /// Whether we stopped telling friends we are online.
  bool get hidden => _hidden;

  Future<void> load() async {
    final raw = await _store.read();
    if (raw != null) {
      final saved = jsonDecode(raw);
      if (saved case {
        'mine': final String mine,
        'sent': final Map<String, Object?> sent,
        'theirs': final Map<String, Object?> theirs,
      }) {
        _mine = mine;
        _hidden = switch (saved) {
          {'hidden': true} => true,
          _ => false,
        };
        for (final MapEntry(:key, :value) in sent.entries) {
          if (value is String) _sent[key] = value;
        }
        for (final MapEntry(:key, :value) in theirs.entries) {
          if (value is String) {
            if (PresenceKey.decode(value) case final known?) {
              _theirs[key] = known;
            }
          }
        }
      }
    }
    if (_mine.isEmpty) {
      final random = Random.secure();
      _mine = [
        for (var i = 0; i < 32; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      await _save();
    }
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'mine': _mine,
      'hidden': _hidden,
      'sent': _sent,
      'theirs': {for (final e in _theirs.entries) e.key: e.value.encode()},
    }),
  );

  bool needsSending(String friend) => _sent[friend] != _mine;

  Future<void> setHidden(bool hidden) async {
    _hidden = hidden;
    await _save();
  }

  Future<void> markSent(String friend) async {
    _sent[friend] = _mine;
    await _save();
  }

  /// Stores [friend]'s key. Returns whether it changed.
  Future<bool> learn(String friend, PresenceKey key) async {
    final known = _theirs[friend];
    if (known?.key == key.key && listEquals(known?.relays, key.relays)) {
      return false;
    }
    _theirs[friend] = key;
    await _save();
    return true;
  }

  Future<void> wipe() => _store.delete();
}

/// Tells friends we are online with one ping per [every], whatever their
/// number: an ephemeral event from a throwaway key, tagged so that only
/// holders of our key recognise it. Relays keep no pings, so one sent on
/// coming online says hello, and friends who see it ping back at once.
class Presence extends ChangeNotifier {
  Presence(
    this._ndk,
    this.book, {
    required this.relays,
    this.every = const Duration(minutes: 2),
    this.fresh = const Duration(minutes: 5),
  });

  final Ndk _ndk;
  final PresenceBook book;
  final List<String> relays;
  final Duration every;

  /// How long after a ping a friend still shows online.
  final Duration fresh;

  final Map<String, DateTime> _seen = {};
  Set<String> _friends = {};
  Map<String, String> _tags = {};
  String? _subscriptionId;
  StreamSubscription<Nip01Event>? _pings;
  Timer? _timer;
  DateTime? _lastReply;
  bool _closed = false;

  /// Answers to hellos are this far apart at least, however many arrive.
  static const _minReply = Duration(seconds: 10);

  PresenceKey get mine => PresenceKey(book.mine, relays);

  bool get visible => !book.hidden;

  /// Hidden, we still see friends; they stop seeing us.
  Future<void> setVisible(bool visible) async {
    if (visible == this.visible) return;
    await book.setHidden(!visible);
    notifyListeners();
    if (book.sharedWithAnyone) _send(visible ? Beat.hello : Beat.bye);
  }

  /// Says hello right away, e.g. after sharing our key with a new friend.
  void greet() {
    if (visible && book.sharedWithAnyone) _send(Beat.hello);
  }

  bool isOnline(String pubkey) {
    final seen = _seen[pubkey];
    return seen != null && DateTime.now().difference(seen) < fresh;
  }

  /// The first [watch] says hello, once friends are known.
  void start() {
    _timer ??= Timer.periodic(every, (_) => _tick());
  }

  /// Listens for these friends' pings.
  void watch(Iterable<String> friends) {
    final next = friends.toSet();
    if (setEquals(next, _friends)) return;
    _friends = next;
    unawaited(_resubscribe());
  }

  /// Stores [friend]'s key from their DM and listens for it.
  Future<void> learn(String friend, PresenceKey key) async {
    if (await book.learn(friend, key)) await _resubscribe(force: true);
  }

  void _tick() {
    if (_closed) return;
    unawaited(_resubscribe());
    // Someone's last ping may just have gone stale.
    notifyListeners();
    if (visible && book.sharedWithAnyone) _send(Beat.alive);
  }

  void _send(Beat beat) => unawaited(
    ping(beat).catchError((Object e) => debugPrint('presence: $e')),
  );

  Future<void> ping(Beat beat) async {
    final signer = _ndk.giftWrap.eventSignerFactory.createWithNewKeyPair();
    final event = await signer.sign(
      Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: presenceKind,
        tags: [
          ['d', presenceTag(book.mine, DateTime.now())],
        ],
        content: beat.content,
      ),
    );
    await publishOnce(_ndk, event, relays);
  }

  /// A window turning over changes every tag, so this runs on each tick and
  /// replaces the subscription only when the tags differ.
  Future<void> _resubscribe({bool force = false}) async {
    if (_closed) return;
    final now = DateTime.now();
    final tags = <String, String>{};
    final listenOn = <String>{...relays};
    for (final friend in _friends) {
      final key = book.theirs[friend];
      if (key == null) continue;
      // A ping just before the turn still counts.
      for (final at in [now, now.subtract(presenceWindow)]) {
        tags[presenceTag(key.key, at)] = friend;
      }
      listenOn.addAll(key.relays);
    }
    if (!force && mapEquals(tags, _tags)) return;
    // A newly heard friend's hello went out before we listened; ours asks
    // them to ping back.
    final added = tags.values.toSet().difference(_tags.values.toSet());
    _tags = tags;
    await _unsubscribe();
    if (tags.isEmpty) return;
    final response = _ndk.requests.subscription(
      filter: Filter(
        kinds: const [presenceKind],
        dTags: tags.keys.toList(),
        since: now.subtract(every).millisecondsSinceEpoch ~/ 1000,
      ),
      explicitRelays: listenOn,
    );
    _subscriptionId = response.requestId;
    _pings = response.stream.listen(_onPing);
    if (added.isNotEmpty) greet();
  }

  void _onPing(Nip01Event event) {
    final tag = event.getFirstTag('d');
    final friend = tag == null ? null : _tags[tag];
    if (friend == null || _closed) return;
    final beat = Beat.of(event.content);
    final wasOnline = isOnline(friend);
    if (beat == Beat.bye) {
      _seen.remove(friend);
      if (wasOnline) notifyListeners();
      return;
    }
    _seen[friend] = DateTime.now();
    if (!wasOnline) notifyListeners();
    final last = _lastReply;
    if (beat == Beat.hello &&
        visible &&
        book.sharedWithAnyone &&
        (last == null || DateTime.now().difference(last) > _minReply)) {
      _lastReply = DateTime.now();
      _send(Beat.alive);
    }
  }

  Future<void> _unsubscribe() async {
    await _pings?.cancel();
    _pings = null;
    final id = _subscriptionId;
    _subscriptionId = null;
    if (id != null) await _ndk.requests.closeSubscription(id);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _unsubscribe();
  }
}
