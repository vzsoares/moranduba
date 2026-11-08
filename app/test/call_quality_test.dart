import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/call_quality.dart';
import 'package:moranduba/core/calls/transport.dart';

LinkStats _link({int received = 0, int lost = 0, int? rttMs, int? jitterMs}) =>
    LinkStats(
      state: 'connected',
      packetsReceived: received,
      packetsLost: lost,
      roundTrip: rttMs == null ? null : Duration(milliseconds: rttMs),
      jitter: jitterMs == null ? null : Duration(milliseconds: jitterMs),
    );

void main() {
  test('levels follow delay, loss and jitter', () {
    expect(qualityOf(), QualityLevel.unknown);
    expect(
      qualityOf(roundTrip: const Duration(milliseconds: 50), loss: 0),
      QualityLevel.good,
    );
    expect(
      qualityOf(roundTrip: const Duration(milliseconds: 250)),
      QualityLevel.fair,
    );
    expect(qualityOf(loss: 0.1), QualityLevel.poor);
    expect(
      qualityOf(jitter: const Duration(milliseconds: 80)),
      QualityLevel.poor,
    );
  });

  test('loss counts only packets since the previous measure', () {
    final meter = QualityMeter();
    expect(
      meter.measure({'a': _link(received: 1000, lost: 500)})['a']!.loss,
      isNull,
    );
    final next = meter.measure({'a': _link(received: 1100, lost: 500)})['a']!;
    expect(next.loss, 0);
    final lossy = meter.measure({'a': _link(received: 1190, lost: 510)})['a']!;
    expect(lossy.loss, closeTo(0.1, 1e-9));
    expect(lossy.level, QualityLevel.poor);
  });

  test('a transport switch restarts the counters without fake loss', () {
    final meter = QualityMeter()..measure({'a': _link(received: 5000)});
    final after = meter.measure({'a': _link(received: 40, rttMs: 30)})['a']!;
    expect(after.loss, isNull);
    expect(after.level, QualityLevel.good);
  });

  test('the worst known link wins', () {
    const good = LinkQuality(level: QualityLevel.good);
    const poor = LinkQuality(level: QualityLevel.poor);
    const unknown = LinkQuality(level: QualityLevel.unknown);
    expect(worstOf([good, unknown, poor]), QualityLevel.poor);
    expect(worstOf([unknown]), QualityLevel.unknown);
    expect(worstOf([good, unknown]), QualityLevel.good);
  });
}
