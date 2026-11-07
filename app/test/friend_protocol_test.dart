import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/friend_protocol.dart';
import 'package:ndk/ndk.dart';

Nip01Event _rumor(List<List<String>> tags) => Nip01Event(
  pubKey: '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e',
  kind: 14,
  tags: tags,
  content: '',
);

FriendState _state(
  List<(Control, bool)> controls, {
  bool storedFriend = false,
}) => friendStateFrom(
  storedFriend: storedFriend,
  controls: [for (final (c, out) in controls) (control: c, outgoing: out)],
);

void main() {
  test('Control.of reads the moranduba tag', () {
    expect(
      Control.of(_rumor(Control.friendRequest.tags)),
      Control.friendRequest,
    );
    expect(Control.of(_rumor(Control.friendAccept.tags)), Control.friendAccept);
    expect(Control.of(_rumor([])), isNull);
    expect(
      Control.of(
        _rumor([
          ['moranduba', 'unknown'],
          ['p', 'x'],
        ]),
      ),
      isNull,
    );
  });

  group('friendStateFrom', () {
    test('no history is none', () => expect(_state([]), FriendState.none));

    test('stored friend wins', () {
      expect(_state([], storedFriend: true), FriendState.friend);
    });

    test('one-sided requests', () {
      expect(_state([(Control.friendRequest, true)]), FriendState.outgoing);
      expect(_state([(Control.friendRequest, false)]), FriendState.incoming);
    });

    test('accept in either direction makes friends', () {
      expect(
        _state([(Control.friendRequest, true), (Control.friendAccept, false)]),
        FriendState.friend,
      );
      expect(
        _state([(Control.friendRequest, false), (Control.friendAccept, true)]),
        FriendState.friend,
      );
    });

    test('crossed requests make friends', () {
      expect(
        _state([(Control.friendRequest, true), (Control.friendRequest, false)]),
        FriendState.friend,
      );
    });
  });
}
