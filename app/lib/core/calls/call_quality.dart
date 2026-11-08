import 'dart:math';

import 'transport.dart';

enum QualityLevel { good, fair, poor, unknown }

class LinkQuality {
  const LinkQuality({
    required this.level,
    this.roundTrip,
    this.loss,
    this.jitter,
  });

  final QualityLevel level;
  final Duration? roundTrip;

  /// Share of packets lost since the last measure, 0 to 1.
  final double? loss;
  final Duration? jitter;
}

QualityLevel qualityOf({Duration? roundTrip, double? loss, Duration? jitter}) {
  if (roundTrip == null && loss == null && jitter == null) {
    return QualityLevel.unknown;
  }
  final rtt = roundTrip?.inMilliseconds ?? 0;
  final lost = loss ?? 0;
  final jit = jitter?.inMilliseconds ?? 0;
  if (lost > 0.08 || rtt > 400 || jit > 60) return QualityLevel.poor;
  if (lost > 0.02 || rtt > 200 || jit > 30) return QualityLevel.fair;
  return QualityLevel.good;
}

/// Turns each link's running packet counters into loss since the previous
/// [measure], so an old burst stops counting against the call.
class QualityMeter {
  final Map<String, ({int received, int lost})> _last = {};

  Map<String, LinkQuality> measure(Map<String, LinkStats> links) {
    _last.removeWhere((participant, _) => !links.containsKey(participant));
    return {
      for (final MapEntry(key: participant, value: link) in links.entries)
        participant: _one(participant, link),
    };
  }

  LinkQuality _one(String participant, LinkStats link) {
    final before = _last[participant];
    _last[participant] = (
      received: link.packetsReceived,
      lost: link.packetsLost,
    );
    double? loss;
    final received = link.packetsReceived - (before?.received ?? 0);
    // Counters restart when the call switches transport.
    if (before != null && received >= 0) {
      // Late packets can make the lost counter go down.
      final lost = max(0, link.packetsLost - before.lost);
      if (received + lost > 0) loss = lost / (received + lost);
    }
    return LinkQuality(
      level: qualityOf(
        roundTrip: link.roundTrip,
        loss: loss,
        jitter: link.jitter,
      ),
      roundTrip: link.roundTrip,
      loss: loss,
      jitter: link.jitter,
    );
  }
}

/// The worst known level among [links].
QualityLevel worstOf(Iterable<LinkQuality> links) {
  var worst = QualityLevel.unknown;
  for (final link in links) {
    if (link.level == QualityLevel.unknown) continue;
    if (worst == QualityLevel.unknown || link.level.index > worst.index) {
      worst = link.level;
    }
  }
  return worst;
}
