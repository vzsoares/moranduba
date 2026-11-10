import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:moranduba/core/calls/call_crypto.dart';
import 'package:moranduba/core/calls/call_signal.dart';
import 'package:moranduba/core/calls/transport.dart';

/// In-memory WebRTC objects: enough of a peer connection for the
/// transports, and a cryptor factory that records every cryptor's life.
var _ids = 0;
String _next(String prefix) => '$prefix${_ids++}';

class FakeTrack extends MediaStreamTrack {
  FakeTrack(this._kind) : _id = _next('track');

  final String _kind;
  final String _id;

  @override
  String get id => _id;

  @override
  String get kind => _kind;

  @override
  Future<MediaStreamTrack> clone() async => FakeTrack(_kind);

  @override
  Future<void> stop() async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeStream extends MediaStream {
  FakeStream(String id, this.tracks) : super(id, 'fake');

  final List<MediaStreamTrack> tracks;

  @override
  List<MediaStreamTrack> getTracks() => tracks;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeSender extends RTCRtpSender {
  FakeSender(this.pc, this._track);

  final FakePeerConnection pc;
  MediaStreamTrack? _track;
  final String _id = _next('sender');

  @override
  MediaStreamTrack? get track => _track;

  @override
  String get senderId => _id;

  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async => _track = track;

  @override
  Future<void> setStreams(List<MediaStream> streams) async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeReceiver extends RTCRtpReceiver {
  FakeReceiver(this.pc, this._track);

  final FakePeerConnection pc;
  final MediaStreamTrack? _track;

  @override
  MediaStreamTrack? get track => _track;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeTransceiver extends RTCRtpTransceiver {
  FakeTransceiver(this._sender, this._receiver);

  final FakeSender _sender;
  final FakeReceiver _receiver;

  @override
  RTCRtpSender get sender => _sender;

  @override
  RTCRtpReceiver get receiver => _receiver;

  @override
  Future<void> setDirection(TransceiverDirection direction) async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeChannel extends RTCDataChannel {
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;

  @override
  Future<void> send(RTCDataChannelMessage message) async {}

  @override
  Future<void> close() async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakePeerConnection extends RTCPeerConnection {
  FakePeerConnection(this._log) : name = _next('pc');

  final String name;
  final List<String> _log;
  final List<FakeTransceiver> _transceivers = [];
  RTCSessionDescription? _local;
  bool closed = false;

  /// The remote stream the far end sends on this link.
  final FakeStream remote = FakeStream(_next('stream'), []);

  FakeTransceiver _add(String kind, MediaStreamTrack? sending) {
    final incoming = FakeTrack(kind);
    remote.tracks.add(incoming);
    final transceiver = FakeTransceiver(
      FakeSender(this, sending),
      FakeReceiver(this, incoming),
    );
    _transceivers.add(transceiver);
    return transceiver;
  }

  /// The far end's tracks arriving, as `track` events.
  void deliverTracks() {
    for (final transceiver in [..._transceivers]) {
      onTrack?.call(
        RTCTrackEvent(
          receiver: transceiver.receiver,
          streams: [remote],
          track: transceiver.receiver.track!,
          transceiver: transceiver,
        ),
      );
    }
  }

  void setState(RTCPeerConnectionState state) => onConnectionState?.call(state);

  @override
  RTCIceGatheringState get iceGatheringState =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, Object?> constraints = const {},
  ]) async => RTCSessionDescription('offer from $name', 'offer');

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, Object?> constraints = const {},
  ]) async => RTCSessionDescription('answer from $name', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async =>
      _local = description;

  @override
  Future<RTCSessionDescription?> getLocalDescription() async => _local;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    if (description.type != 'offer') return;
    for (final kind in ['audio', 'video']) {
      if (!_transceivers.any((t) => t.receiver.track?.kind == kind)) {
        _add(kind, null);
      }
    }
  }

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async {
    _alive();
    for (final transceiver in _transceivers) {
      if (transceiver.receiver.track?.kind == track.kind &&
          transceiver.sender.track == null) {
        await transceiver.sender.replaceTrack(track);
        return transceiver.sender;
      }
    }
    return _add(track.kind!, track).sender;
  }

  @override
  Future<RTCRtpTransceiver> addTransceiver({
    MediaStreamTrack? track,
    RTCRtpMediaType? kind,
    RTCRtpTransceiverInit? init,
  }) async {
    _alive();
    final name = kind == RTCRtpMediaType.RTCRtpMediaTypeAudio
        ? 'audio'
        : 'video';
    return _add(name, track);
  }

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async => FakeChannel();

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => [..._transceivers];

  @override
  Future<void> close() async {
    closed = true;
    _log.add('close $name');
  }

  void _alive() {
    if (closed) throw StateError('$name is closed');
  }

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeCryptor extends FrameCryptor {
  FakeCryptor(this.pc, this._factory) : name = _next('cryptor');

  final FakePeerConnection pc;
  final FakeCryptorFactory _factory;
  final String name;
  bool disposed = false;

  @override
  String get participantId => 'fake';

  @override
  Future<bool> setEnabled(bool enabled) async => true;

  @override
  Future<bool> setKeyIndex(int index) async => true;

  @override
  Future<void> dispose() async {
    if (disposed) throw StateError('$name disposed twice');
    disposed = true;
    _factory._disposed(this);
  }

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeKeys extends KeyProvider {
  @override
  String get id => 'keys';

  @override
  Future<void> setSharedKey({required Uint8List key, int index = 0}) async {}

  @override
  Future<void> dispose() async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeCryptorFactory extends FrameCryptorFactory {
  final List<String> log = [];
  final List<FakeCryptor> live = [];

  /// Cryptors disposed while their link was still open.
  final List<String> disposedOpen = [];

  void _disposed(FakeCryptor cryptor) {
    live.remove(cryptor);
    log.add('dispose ${cryptor.pc.name}');
    if (!cryptor.pc.closed) disposedOpen.add(cryptor.pc.name);
  }

  FakeCryptor _create(FakePeerConnection pc) {
    final cryptor = FakeCryptor(pc, this);
    live.add(cryptor);
    log.add('create ${pc.name}');
    return cryptor;
  }

  @override
  Future<KeyProvider> createDefaultKeyProvider(
    KeyProviderOptions options,
  ) async => FakeKeys();

  @override
  Future<FrameCryptor> createFrameCryptorForRtpSender({
    required String participantId,
    required RTCRtpSender sender,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async => switch (sender) {
    FakeSender(:final pc) => _create(pc),
    _ => throw ArgumentError('not a fake sender'),
  };

  @override
  Future<FrameCryptor> createFrameCryptorForRtpReceiver({
    required String participantId,
    required RTCRtpReceiver receiver,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async => switch (receiver) {
    FakeReceiver(:final pc) => _create(pc),
    _ => throw ArgumentError('not a fake receiver'),
  };

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

/// A call as the transports see it, with fake links and cryptors.
class FakeHost implements CallHost {
  FakeHost(this.me, this.crypto, this.factory);

  static Future<FakeHost> create(String me) async {
    final factory = FakeCryptorFactory();
    return FakeHost(me, await CallCrypto.create(factory: factory), factory);
  }

  @override
  final String me;
  @override
  final CallCrypto crypto;
  final FakeCryptorFactory factory;
  final List<FakePeerConnection> links = [];
  final List<CallSignal> signals = [];
  final Map<String, String> states = {};

  late final FakeStream _local = FakeStream('local', [
    FakeTrack('audio'),
    FakeTrack('video'),
  ]);

  Future<RTCPeerConnection> connect(Map<String, Object> config) async {
    final pc = FakePeerConnection(factory.log);
    links.add(pc);
    return pc;
  }

  List<FakePeerConnection> get open => [
    for (final pc in links)
      if (!pc.closed) pc,
  ];

  @override
  String get callId => 'call';

  @override
  List<MediaStreamTrack> get outgoingTracks => _local.tracks;

  @override
  MediaStream get outgoingStream => _local;

  @override
  Future<void> signal(CallSignal signal) async => signals.add(signal);

  @override
  void remoteStream(String participant, MediaStream stream) {}

  @override
  void peerState(String participant, String state) =>
      states[participant] = state;

  @override
  void peerGone(String participant) => states.remove(participant);

  @override
  void linksChanged() {}
}
