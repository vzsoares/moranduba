import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'receiver_e2ee.dart';

/// The cryptors of one peer connection.
class _LinkCryptors {
  final List<FrameCryptor> senders = [];
  final List<FrameCryptor> receivers = [];
  final Map<FrameCryptor, String> receiverTracks = {};

  int get count => senders.length + receivers.length;
}

/// Frame encryption for one call. The key comes from the group's MLS
/// exporter; each epoch gets its own slot in the key ring, so frames sent
/// under the previous epoch still decrypt during a membership change.
///
/// Each link owns its cryptors. [release] frees them once the link is
/// closed, so redials, relay retries and mode switches do not pile them up.
class CallCrypto {
  CallCrypto._(this._factory, this._keys);

  static const ringSize = 16;

  static Future<CallCrypto> create({FrameCryptorFactory? factory}) async {
    final cryptors = factory ?? frameCryptorFactory;
    final keys = await cryptors.createDefaultKeyProvider(
      KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: Uint8List.fromList(utf8.encode('moranduba-call')),
        ratchetWindowSize: 0,
        keyRingSize: ringSize,
        // No plaintext ever leaves before a key is in place.
        discardFrameWhenCryptorNotReady: true,
        keyDerivationAlgorithm: KeyDerivationAlgorithm.kHKDF,
      ),
    );
    activateReceiverKeys(keys.id);
    return CallCrypto._(cryptors, keys);
  }

  final FrameCryptorFactory _factory;
  final KeyProvider _keys;
  final Map<RTCPeerConnection, _LinkCryptors> _links = {};

  /// Links already released; a cryptor that finishes setting up for one is
  /// disposed at once.
  final Expando<bool> _released = Expando();
  final Map<String, FrameCryptorState> states = {};
  final Map<FrameCryptor, String> _labels = {};
  final Set<String> _decrypting = {};
  Timer? _settler;
  int? _index;
  bool _disposed = false;

  int? get keyIndex => _index;

  /// Links that still hold cryptors.
  int get linkCount => _links.length;

  /// Cryptors not yet disposed.
  int get cryptorCount =>
      _links.values.fold(0, (sum, link) => sum + link.count);

  Iterable<FrameCryptor> get _senders =>
      _links.values.expand((link) => link.senders);

  /// Installs the key for [epoch] and moves senders onto it.
  Future<void> setKey(Uint8List key, int epoch) async {
    final index = epoch % ringSize;
    await _keys.setSharedKey(key: key, index: index);
    _index = index;
    for (final cryptor in [..._senders]) {
      await cryptor.setKeyIndex(index);
    }
  }

  bool _gone(RTCPeerConnection link) => _disposed || (_released[link] ?? false);

  Future<void> encrypt(
    RTCRtpSender sender,
    String me, {
    required RTCPeerConnection link,
  }) async {
    if (_gone(link)) return;
    final cryptor = await _factory.createFrameCryptorForRtpSender(
      participantId: me,
      sender: sender,
      algorithm: Algorithm.kAesGcm,
      keyProvider: _keys,
    );
    if (_gone(link)) return _dispose(cryptor);
    _watch(cryptor, 'out:${sender.track?.kind}:${sender.track?.id}');
    (_links[link] ??= _LinkCryptors()).senders.add(cryptor);
    await _apply(cryptor);
  }

  /// Attach right after the transceiver exists: Chrome ignores a receiver
  /// transform added once frames may have arrived. Returns false when the
  /// receiver has no track yet or is already handled.
  Future<bool> decrypt(
    RTCRtpReceiver receiver,
    String participant, {
    required RTCPeerConnection link,
  }) async {
    final trackId = receiver.track?.id;
    if (trackId == null || _gone(link) || !_decrypting.add(trackId)) {
      return false;
    }
    final cryptor = await _factory.createFrameCryptorForRtpReceiver(
      participantId: participant,
      receiver: receiver,
      algorithm: Algorithm.kAesGcm,
      keyProvider: _keys,
    );
    if (_gone(link)) {
      _decrypting.remove(trackId);
      await _dispose(cryptor);
      return false;
    }
    _watch(cryptor, 'in:${receiver.track?.kind}:${receiver.track?.id}');
    final owner = _links[link] ??= _LinkCryptors();
    owner.receivers.add(cryptor);
    owner.receiverTracks[cryptor] = trackId;
    await _apply(cryptor);
    return true;
  }

  /// Disposes [link]'s cryptors. Call it after closing [link]: a cryptor
  /// disposed while its sender still runs would stop encrypting it.
  Future<void> release(RTCPeerConnection link) async {
    _released[link] = true;
    final owned = _links.remove(link);
    if (owned == null) return;
    _decrypting.removeAll(owned.receiverTracks.values);
    for (final cryptor in [...owned.senders, ...owned.receivers]) {
      final label = _labels.remove(cryptor);
      // The same local track is encrypted once per link, under one label.
      if (label != null && !_labels.containsValue(label)) states.remove(label);
      await _dispose(cryptor);
    }
  }

  Future<void> _dispose(FrameCryptor cryptor) async {
    try {
      await cryptor.dispose();
    } catch (e) {
      debugPrint('dispose cryptor: $e');
    }
  }

  /// On web the worker builds its cryptor only when the first encoded frame
  /// passes, which for receivers is after the link connects. Settings sent
  /// before then are dropped, so they are repeated until a state comes back.
  void _settleLater() {
    _settler ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      final pending = [
        for (final entry in _labels.entries)
          if (states[entry.value] == FrameCryptorState.FrameCryptorStateNew)
            entry.key,
      ];
      for (final cryptor in pending) {
        await _apply(cryptor);
      }
    });
  }

  Future<void> _apply(FrameCryptor cryptor) async {
    try {
      if (_index case final index? when _senders.contains(cryptor)) {
        await cryptor.setKeyIndex(index);
      }
      await cryptor.setEnabled(true);
    } catch (_) {
      // Disposed while a retry was pending.
    }
  }

  void _watch(FrameCryptor cryptor, String label) {
    _labels[cryptor] = label;
    states[label] = FrameCryptorState.FrameCryptorStateNew;
    _settleLater();
    cryptor.onFrameCryptorStateChanged = (_, state) => states[label] = state;
  }

  /// Sender and receiver cryptor states by label.
  Map<String, String> get allStates => {
    for (final entry in states.entries) entry.key: entry.value.name,
    for (final entry in receiverStates().entries)
      'in:${entry.key}': entry.value == 'ok'
          ? FrameCryptorState.FrameCryptorStateOk.name
          : entry.value,
  };

  /// Call end, after every link closed.
  Future<void> dispose() async {
    _disposed = true;
    activateReceiverKeys(null);
    _settler?.cancel();
    _labels.clear();
    states.clear();
    for (final link in [..._links.keys]) {
      await release(link);
    }
    _decrypting.clear();
    await _keys.dispose();
  }
}
