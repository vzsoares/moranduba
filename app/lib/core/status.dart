import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:ndk/ndk.dart';

enum Health { ok, slow, down }

/// One row of the connection status page.
class StatusCheck {
  const StatusCheck(this.health, this.detail, {this.latency});

  final Health health;
  final String detail;
  final Duration? latency;
}

/// Answers slower than this still work but show as slow.
const slowAnswer = Duration(milliseconds: 800);

/// Probes for the connection status page.
class StatusProbe {
  StatusProbe(
    this._ndk, {
    required this.me,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  /// Ephemeral, so relays answer OK or say why not, and store nothing.
  static const probeKind = 20999;

  final Ndk _ndk;
  final _random = Random.secure();
  final String me;
  final http.Client _client;
  final Duration timeout;

  /// Publishes a throwaway ephemeral event to [url]; a relay that bans or
  /// rate-limits us says so in its OK.
  Future<StatusCheck> relay(String url) => _timed(() async {
    final responses = await _ndk.broadcast
        .broadcast(
          nostrEvent: Nip01Event(
            pubKey: me,
            kind: probeKind,
            tags: const [],
            // ndk tracks broadcasts by event id; parallel probes must differ.
            content: '${_random.nextInt(0x7fffffff)}',
          ),
          specificRelays: [url],
          timeout: timeout,
          saveToCache: false,
          retryDelivery: false,
        )
        .broadcastDoneFuture;
    final response =
        responses.where((r) => _sameRelay(r.relayUrl, url)).firstOrNull ??
        responses.firstOrNull;
    if (response == null) throw const _Refused('No answer');
    if (!response.broadcastSuccessful) {
      throw _Refused(
        response.msg.isEmpty
            ? (response.okReceived ? 'Refused our message' : 'No answer')
            // ndk appends a null error to some messages.
            : response.msg.replaceFirst(RegExp(r' null$'), ''),
      );
    }
  });

  /// Any HTTP answer below 500 means the Blossom server is up.
  Future<StatusCheck> fileServer(String url) => _timed(() async {
    final response = await _client.head(Uri.parse(url));
    if (response.statusCode >= 500) {
      throw _Refused('HTTP ${response.statusCode}');
    }
  });

  /// Times [ping]; what it throws becomes the row's detail.
  Future<StatusCheck> callServer(Future<void> Function() ping) => _timed(ping);

  Future<StatusCheck> _timed(Future<void> Function() run) async {
    final watch = Stopwatch()..start();
    try {
      await run().timeout(timeout + const Duration(seconds: 2));
    } on TimeoutException {
      return const StatusCheck(Health.down, 'No answer in time');
    } catch (e) {
      return StatusCheck(Health.down, describeError(e));
    }
    final latency = watch.elapsed;
    return StatusCheck(
      latency < slowAnswer ? Health.ok : Health.slow,
      latency < slowAnswer ? 'Working' : 'Working, but slow',
      latency: latency,
    );
  }
}

bool _sameRelay(String a, String b) =>
    a.replaceFirst(RegExp(r'/$'), '') == b.replaceFirst(RegExp(r'/$'), '');

class _Refused implements Exception {
  const _Refused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [error] without its Dart class prefix.
String describeError(Object error) =>
    '$error'.replaceFirst(RegExp(r'^(Bad state|\w*Exception): '), '');
