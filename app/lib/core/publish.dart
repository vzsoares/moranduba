import 'package:ndk/ndk.dart';

/// Sends [event] once to [relays]; true as soon as one takes it. ndk would
/// otherwise keep resending regular events to every relay that refused,
/// and a relay that rate-limits us bans the IP for the repeats. Callers
/// that need delivery retry themselves (outbox, key package backoff).
Future<bool> publishOnce(Ndk ndk, Nip01Event event, Iterable<String> relays) =>
    acceptedByAny(
      ndk.broadcast.broadcast(
        nostrEvent: event,
        specificRelays: relays,
        retryDelivery: false,
      ),
    );

/// Whether any relay took the event, known as soon as one does. ndk's
/// done future waits for every relay, so one silent relay would hold each
/// publish for the whole broadcast timeout.
Future<bool> acceptedByAny(NdkBroadcastResponse response) async {
  await for (final responses in response.broadcastDone) {
    if (responses.any((r) => r.broadcastSuccessful)) return true;
  }
  return false;
}
