import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moranduba/core/calls/call_signal.dart';
import 'package:moranduba/core/calls/calls.dart';
import 'package:moranduba/core/groups/group_engine.dart';
import 'package:moranduba/core/groups/groups.dart';

class _Groups extends Mock implements Groups {}

final _me = 'b' * 64;
final _alice = 'a' * 64;
var _ids = 0;

GroupSignal _signal(SignalType type, {String? to}) => GroupSignal(
  id: '${_ids++}',
  groupId: 'g1',
  sender: _alice,
  payload: CallSignal(type: type, callId: 'c1', to: to).encode(),
  createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
);

void main() {
  late StreamController<GroupSignal> signals;
  late Calls calls;

  setUp(() {
    signals = StreamController<GroupSignal>();
    final groups = _Groups();
    when(() => groups.signals).thenAnswer((_) => signals.stream);
    when(() => groups.me).thenReturn(_me);
    calls = Calls(groups);
  });

  tearDown(() => signals.close());

  Future<void> send(GroupSignal signal) async {
    signals.add(signal);
    await pumpEventQueue();
  }

  test('a running call rings us again when someone asks', () async {
    await send(_signal(SignalType.join));
    expect(calls.ringing?.callId, 'c1');
    calls.decline();

    await send(_signal(SignalType.join));
    expect(calls.ringing, isNull, reason: 'one ring per call on its own');

    await send(_signal(SignalType.ring, to: _me));
    expect(calls.ringing?.caller, _alice);
  });

  test('a ring for someone else stays quiet; one for all rings', () async {
    await send(_signal(SignalType.ring, to: 'c' * 64));
    expect(calls.ringing, isNull);
    await send(_signal(SignalType.ring));
    expect(calls.ringing?.groupId, 'g1');
  });
}
