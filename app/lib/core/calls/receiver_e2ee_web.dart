import 'dart:js_interop';

/// Set up by web/e2ee_receivers.js, which decrypts every incoming track.
@JS('morandubaE2ee')
external _ReceiverE2ee? get _e2ee;

extension type _ReceiverE2ee._(JSObject _) implements JSObject {
  external set keyProviderId(String? id);
  external JSObject get states;
}

bool get receiversHandledByPage => _e2ee != null;

/// Points page-level receiver decryption at the call's key provider, or
/// stops it with null.
void activateReceiverKeys(String? keyProviderId) =>
    _e2ee?.keyProviderId = keyProviderId;

Map<String, String> receiverStates() {
  final states = _e2ee?.states.dartify();
  if (states is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in states.entries)
      if (key is String && value is String) key: value,
  };
}
