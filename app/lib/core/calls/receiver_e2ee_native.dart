/// Native libwebrtc accepts receiver frame cryptors at any time, so
/// receivers are handled per track in Dart.
bool get receiversHandledByPage => false;

bool pageDecrypts(String trackId) => false;

void activateReceiverKeys(String? keyProviderId) {}

void releaseClosedReceivers() {}

Future<int?> workerCryptorCount() async => null;

Map<String, String> receiverStates() => const {};
