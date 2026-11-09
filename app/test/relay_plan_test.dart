import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/call_signal.dart';
import 'package:moranduba/core/calls/relay_plan.dart';
import 'package:moranduba/core/calls/transport.dart';

final _a = 'a' * 64;
final _b = 'b' * 64;
final _c = 'c' * 64;
final _d = 'd' * 64;

LinkReport _report({
  Set<String> links = const {},
  Set<String> failed = const {},
}) => LinkReport(links: links, failed: failed);

void main() {
  group('relay plan', () {
    test('a failed pair goes through the member linked to both', () {
      final reports = {
        _a: _report(links: {_c}, failed: {_b}),
        _b: _report(links: {_c}),
        _c: _report(links: {_a, _b}),
      };
      expect(relayFor(_a, _b, reports), _c);
      expect(relayJobs(_c, reports), {
        (origin: _a, target: _b),
        (origin: _b, target: _a),
      });
      expect(relayJobs(_a, reports), isEmpty);
      expect(relayJobs(_b, reports), isEmpty);
    });

    test('one side reporting the failure is enough', () {
      final reports = {
        _a: _report(links: {_c}),
        _b: _report(links: {_c}, failed: {_a}),
        _c: _report(links: {_a, _b}),
      };
      expect(relayFor(_a, _b, reports), _c);
    });

    test('no relay while the pair is fine or nobody reaches both', () {
      expect(
        relayFor(_a, _b, {
          _a: _report(links: {_b, _c}),
          _b: _report(links: {_a, _c}),
          _c: _report(links: {_a, _b}),
        }),
        isNull,
      );
      expect(
        relayFor(_a, _b, {
          _a: _report(links: {_c}, failed: {_b}),
          _b: _report(),
          _c: _report(links: {_a}),
        }),
        isNull,
      );
    });

    test('clients that send no report are never relayed', () {
      final reports = {
        _a: _report(links: {_c}, failed: {_b}),
        _c: _report(links: {_a, _b}),
      };
      expect(relayFor(_a, _b, reports), isNull);
      expect(relayJobs(_c, reports), isEmpty);
    });

    test('everyone picks the same relay, whatever order they heard', () {
      final reports = {
        _a: _report(links: {_c, _d}, failed: {_b}),
        _b: _report(links: {_c, _d}, failed: {_a}),
        _c: _report(links: {_a, _b, _d}),
        _d: _report(links: {_a, _b, _c}),
      };
      final reversed = Map.fromEntries(reports.entries.toList().reversed);
      final relay = relayFor(_a, _b, reports);
      expect(relay, isIn([_c, _d]));
      expect(relayFor(_b, _a, reversed), relay);
      final other = relay == _c ? _d : _c;
      expect(relayJobs(relay!, reports), hasLength(2));
      expect(relayJobs(other, reports), isEmpty);
    });

    test('pairs spread over candidates', () {
      final people = [for (var i = 0; i < 12; i++) i.toRadixString(16) * 64];
      final [relay1, relay2, ...ends] = people;
      final reports = <String, LinkReport>{
        relay1: _report(links: ends.toSet()),
        relay2: _report(links: ends.toSet()),
        for (final end in ends)
          end: _report(
            links: {relay1, relay2},
            failed: ends.where((e) => e != end).toSet(),
          ),
      };
      expect(relayJobs(relay1, reports), isNotEmpty);
      expect(relayJobs(relay2, reports), isNotEmpty);
    });
  });

  test('fnv1a matches the reference values', () {
    expect(fnv1a(''), 0x811c9dc5);
    expect(fnv1a('a'), 0xe40c292c);
    expect(fnv1a('foobar'), 0xbf9cf968);
  });

  test('redials back off up to a minute', () {
    expect(
      [for (var i = 1; i <= 8; i++) redialDelay(i).inSeconds],
      [0, 5, 10, 20, 40, 60, 60, 60],
    );
  });

  test('stripped SDP leaves no address to reach', () {
    const sdp =
        'v=0\r\n'
        'm=audio 54321 UDP/TLS/RTP/SAVPF 111\r\n'
        'c=IN IP4 192.168.1.5\r\n'
        'a=candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host\r\n'
        'a=mid:0\r\n';
    final stripped = withoutCandidates(sdp);
    expect(stripped, isNot(contains('a=candidate')));
    expect(stripped, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111'));
    expect(stripped, contains('c=IN IP4 0.0.0.0'));
    expect(stripped, contains('a=mid:0'));
  });

  test('link reports and relay signals survive the wire', () {
    final here = CallSignal.decode(
      CallSignal(
        type: SignalType.here,
        callId: 'c1',
        mode: 'mesh',
        report: _report(links: {_a}, failed: {_b}),
      ).encode(),
    );
    expect(here?.report?.links, {_a});
    expect(here?.report?.failed, {_b});

    final offer = CallSignal.decode(
      CallSignal(
        type: SignalType.relayOffer,
        callId: 'c1',
        to: _b,
        origin: _a,
        sdp: 'v=0',
      ).encode(),
    );
    expect(offer?.type, SignalType.relayOffer);
    expect(offer?.origin, _a);
    expect(offer?.report, isNull);
    expect(
      CallSignal.decode('{"t":"relay_answer","call":"c1"}')?.type,
      SignalType.relayAnswer,
    );
  });

  test('reports compare by content', () {
    expect(_report(links: {_a, _b}).sameAs(_report(links: {_b, _a})), isTrue);
    expect(_report(links: {_a}).sameAs(_report(failed: {_a})), isFalse);
  });

  test('relayed link stats name the relay', () {
    expect(const LinkStats(state: 'connected', via: 'c').toJson()['via'], 'c');
    expect(
      const LinkStats(state: 'connected').toJson(),
      isNot(contains('via')),
    );
  });
}
