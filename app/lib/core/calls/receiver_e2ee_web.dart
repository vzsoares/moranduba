import 'dart:js_interop';

/// Set up by web/e2ee_receivers.js, which decrypts every incoming track.
@JS('morandubaE2ee')
external _ReceiverE2ee? get _e2ee;

extension type _ReceiverE2ee._(JSObject _) implements JSObject {
  external set keyProviderId(String? id);
  external JSObject get states;
  external bool handles(String trackId);
  external void purge();
  external JSPromise<JSNumber> cryptorCount();
}

bool get receiversHandledByPage => _e2ee != null;

/// Whether the page already decrypts the receiver of [trackId].
bool pageDecrypts(String trackId) => _e2ee?.handles(trackId) ?? false;

/// Points page-level receiver decryption at the call's key provider, or
/// stops it with null.
void activateReceiverKeys(String? keyProviderId) =>
    _e2ee?.keyProviderId = keyProviderId;

/// Frees the page's receiver cryptors of closed links.
void releaseClosedReceivers() => _e2ee?.purge();

/// Frame cryptors alive in dart_webrtc's worker; null off the web.
Future<int?> workerCryptorCount() async => switch (_e2ee) {
  final e2ee? => (await e2ee.cryptorCount().toDart).toDartInt,
  null => null,
};

Map<String, String> receiverStates() {
  final states = _e2ee?.states.dartify();
  if (states is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in states.entries)
      if (key is String && value is String) key: value,
  };
}
