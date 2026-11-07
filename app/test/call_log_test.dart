import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/calls/call_log.dart';
import 'package:moranduba/core/groups/group_engine.dart';

GroupMessage _message(String text, {bool call = false, int at = 0}) =>
    GroupMessage(
      id: '$at',
      groupId: 'g',
      sender: 'alice',
      text: text,
      createdAt: at,
      call: call,
    );

void main() {
  test('events round-trip; other JSON is not an event', () {
    final start = CallEvent.decode(const CallEvent.started('c1').encode());
    expect(start?.callId, 'c1');
    expect(start?.ended, isFalse);
    final end = CallEvent.decode(
      const CallEvent.ended('c1', seconds: 75).encode(),
    );
    expect(end?.seconds, 75);
    expect(CallEvent.decode('{"t":"profile"}'), isNull);
    expect(CallEvent.decode('not json'), isNull);
  });

  test('a call shows as one row that gains its length when it ends', () {
    final items = withCallLog([
      _message('hi', at: 1),
      _message(const CallEvent.started('c1').encode(), call: true, at: 2),
      _message('during', at: 3),
      _message(
        const CallEvent.ended('c1', seconds: 125).encode(),
        call: true,
        at: 4,
      ),
      _message(const CallEvent.started('c2').encode(), call: true, at: 5),
      // An end whose start was pruned.
      _message(
        const CallEvent.ended('c0', seconds: 9).encode(),
        call: true,
        at: 6,
      ),
    ]);
    expect(items, hasLength(4));
    expect(items[1], isA<CallLogEntry>());
    final done = items[1];
    expect(done is CallLogEntry ? done.seconds : null, 125);
    final ongoing = items[3];
    expect(ongoing is CallLogEntry ? ongoing.seconds : -1, isNull);
  });

  test('lengths and previews read naturally', () {
    expect(callLength(35), '35s');
    expect(callLength(250), '4m 10s');
    expect(callLength(3720), '1h 2m');
    expect(
      messagePreview(
        _message(const CallEvent.started('c').encode(), call: true),
      ),
      'started a call',
    );
    expect(
      messagePreview(
        _message(const CallEvent.ended('c', seconds: 61).encode(), call: true),
      ),
      'call ended · 1m 1s',
    );
    expect(messagePreview(_message('plain')), 'plain');
  });
}
