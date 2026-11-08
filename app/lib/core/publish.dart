import 'package:ndk/ndk.dart';

/// Whether any relay took the event, known as soon as one does. ndk's
/// done future waits for every relay, so one silent relay would hold each
/// publish for the whole broadcast timeout.
Future<bool> acceptedByAny(NdkBroadcastResponse response) async {
  await for (final responses in response.broadcastDone) {
    if (responses.any((r) => r.broadcastSuccessful)) return true;
  }
  return false;
}
