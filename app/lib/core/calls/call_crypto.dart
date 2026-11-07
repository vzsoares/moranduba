import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'receiver_e2ee.dart';

/// Frame encryption for one call. The key comes from the group's MLS
/// exporter; each epoch gets its own slot in the key ring, so frames sent
/// under the previous epoch still decrypt during a membership change.
class CallCrypto {
  CallCrypto._(this._keys);

  static const ringSize = 16;

  static Future<CallCrypto> create() async {
    final keys = await frameCryptorFactory.createDefaultKeyProvider(
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
    return CallCrypto._(keys);
  }

  final KeyProvider _keys;
  final List<FrameCryptor> _senders = [];
  final List<FrameCryptor> _receivers = [];
  final Map<String, FrameCryptorState> states = {};
  final Map<FrameCryptor, String> _labels = {};
  Timer? _settler;
  int? _index;

  int? get keyIndex => _index;

  /// Installs the key for [epoch] and moves senders onto it.
  Future<void> setKey(Uint8List key, int epoch) async {
    final index = epoch % ringSize;
    await _keys.setSharedKey(key: key, index: index);
    _index = index;
    for (final cryptor in _senders) {
      await cryptor.setKeyIndex(index);
    }
  }

  Future<void> encrypt(RTCRtpSender sender, String me) async {
    final cryptor = await frameCryptorFactory.createFrameCryptorForRtpSender(
      participantId: me,
      sender: sender,
      algorithm: Algorithm.kAesGcm,
      keyProvider: _keys,
    );
    _watch(cryptor, 'out:${sender.track?.kind}:${sender.track?.id}');
    _senders.add(cryptor);
    await _apply(cryptor);
  }

  final Set<String> _decrypting = {};

  /// Attach right after the transceiver exists: Chrome ignores a receiver
  /// transform added once frames may have arrived. Returns false when the
  /// receiver has no track yet or is already handled.
  Future<bool> decrypt(RTCRtpReceiver receiver, String participant) async {
    final trackId = receiver.track?.id;
    if (trackId == null || !_decrypting.add(trackId)) return false;
    final cryptor = await frameCryptorFactory.createFrameCryptorForRtpReceiver(
      participantId: participant,
      receiver: receiver,
      algorithm: Algorithm.kAesGcm,
      keyProvider: _keys,
    );
    _watch(cryptor, 'in:${receiver.track?.kind}:${receiver.track?.id}');
    _receivers.add(cryptor);
    await _apply(cryptor);
    return true;
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
      if (_senders.contains(cryptor) && _index != null) {
        await cryptor.setKeyIndex(_index!);
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

  Future<void> dispose() async {
    activateReceiverKeys(null);
    _settler?.cancel();
    _labels.clear();
    for (final cryptor in [..._senders, ..._receivers]) {
      await cryptor.dispose();
    }
    _senders.clear();
    _receivers.clear();
    await _keys.dispose();
  }
}
