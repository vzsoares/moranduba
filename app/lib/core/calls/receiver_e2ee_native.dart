/// Native libwebrtc accepts receiver frame cryptors at any time, so
/// receivers are handled per track in Dart.
bool get receiversHandledByPage => false;

void activateReceiverKeys(String? keyProviderId) {}

Map<String, String> receiverStates() => const {};
