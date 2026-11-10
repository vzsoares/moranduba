import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_signal.dart';
import 'receiver_e2ee.dart';
import 'relay_plan.dart';
import 'transport.dart';

/// A direct link that is not connected by then counts as failed.
const connectTimeout = Duration(seconds: 20);

/// A relay link that failed waits this long before the plan tries again.
const _relayRetry = Duration(seconds: 5);

/// A relay link into this device: [origin]'s media, forwarded by [via].
class _Incoming {
  _Incoming(this.via, this.pc);

  final String via;
  final RTCPeerConnection pc;
  MediaStream? stream;
  bool connected = false;
}

/// A relay link this device serves.
class _Outgoing {
  _Outgoing(this.pc, {required this.blocked});

  final RTCPeerConnection pc;

  /// [MeshTransport.relayBlocked] held when its offer went out.
  final bool blocked;

  /// Track clones it forwards, stopped with it.
  final List<MediaStreamTrack> clones = [];
  bool stopped = false;
}

/// Every participant connects to every other. For each pair the lower pubkey
/// dials, so two offers never cross. A pair whose direct link fails gets its
/// media through a third participant (ADR 0003).
class MeshTransport implements CallTransport {
  MeshTransport(
    this._host, {
    this.iceServers = defaultIceServers,
    this.directBlocked,
    this.relayBlocked,
    this.connect = openPeerConnection,
    this.cloneForwarded = kIsWeb,
  });

  final CallHost _host;
  final List<Map<String, String>> iceServers;
  final PeerConnector connect;

  /// Tests: the direct link to these participants carries no candidates,
  /// so it fails.
  final bool Function(String participant)? directBlocked;

  /// Tests: relay links this device serves to these participants carry no
  /// candidates, so they fail.
  final bool Function(String participant)? relayBlocked;

  /// Forward clones of received tracks, so our own deafen or mute does not
  /// reach them. Native flutter_webrtc cannot clone.
  final bool cloneForwarded;

  final Map<String, RTCPeerConnection> _links = {};

  /// The stream each direct link delivers, shown once that link connects.
  final Map<String, MediaStream> _direct = {};
  final Set<String> _connected = {};
  final Set<String> _failed = {};
  final Map<String, int> _failures = {};

  /// Connect timeouts, and redials waiting out their backoff.
  final Map<String, Timer> _timers = {};
  final Map<String, LinkReport> _reports = {};
  final Map<String, _Incoming> _incoming = {};
  final Map<RelayJob, _Outgoing?> _serving = {};
  Timer? _replanTimer;

  /// Failed peers whose planned relay has until the timer to connect.
  final Map<String, ({String via, Timer timer})> _relayWait = {};

  /// Failed peers and the relay that failed or never connected for them.
  final Map<String, String> _relayGaveUp = {};

  /// The state last handed to the host, by participant.
  final Map<String, String> _published = {};

  /// Senders that already have a frame encryptor, by link: native sender
  /// ids are track ids, so they repeat across links.
  final Map<RTCPeerConnection, Set<String>> _encrypted = {};
  final Set<String> _dialing = {};
  bool _closed = false;

  @override
  String get mode => 'mesh';

  @override
  String? get sfu => null;

  @override
  LinkReport get linkReport =>
      LinkReport(links: {..._connected}, failed: {..._failed});

  @override
  Future<void> start() async {}

  @override
  Future<void> participantSeen(String participant) async {
    if (_closed || participant == _host.me) return;
    if (_links.containsKey(participant) ||
        _dialing.contains(participant) ||
        _timers.containsKey(participant)) {
      return;
    }
    if (_dials(participant)) await _dial(participant);
  }

  bool _dials(String participant) => _host.me.compareTo(participant) < 0;

  @override
  Future<void> participantMedia(String participant, MediaState media) async {}

  @override
  Future<void> participantLinks(String participant, LinkReport report) async {
    if (_closed || participant == _host.me) return;
    final previous = _reports[participant];
    _reports[participant] = report;
    if (previous == null || !previous.sameAs(report)) _reportsChanged();
  }

  @override
  Future<void> onSignal(String from, CallSignal signal) async {
    if (_closed || signal.to != _host.me) return;
    final sdp = signal.sdp;
    if (sdp == null) return;
    switch (signal.type) {
      case SignalType.offer:
        // The old link closes only once the new one encrypts.
        final old = _detach(from);
        final RTCPeerConnection pc;
        try {
          pc = await _link(from, offer: _sdp(from, sdp));
        } finally {
          if (old != null) await _closeQuietly(old, 'link $from');
        }
        await pc.setLocalDescription(await pc.createAnswer());
        final answer = await gatheredDescription(pc);
        if (answer?.sdp case final sdp?) {
          await _host.signal(
            CallSignal(
              type: SignalType.answer,
              callId: _host.callId,
              to: from,
              sdp: _sdp(from, sdp),
            ),
          );
        }
      case SignalType.answer:
        await _links[from]?.setRemoteDescription(
          RTCSessionDescription(_sdp(from, sdp), 'answer'),
        );
      case SignalType.relayOffer:
        // A relay planned from reports older than our direct link is moot.
        if (signal.origin case final origin?
            when origin != _host.me &&
                origin != from &&
                !_connected.contains(origin)) {
          await _acceptRelay(from, origin, sdp);
        }
      case SignalType.relayAnswer:
        if (signal.origin case final origin?) {
          final out = _serving[(origin: origin, target: from)];
          await out?.pc.setRemoteDescription(
            RTCSessionDescription(
              out.blocked ? withoutCandidates(sdp) : sdp,
              'answer',
            ),
          );
        }
      default:
        break;
    }
  }

  /// Direct-link SDP, both ways, as [directBlocked] allows.
  String _sdp(String participant, String sdp) =>
      directBlocked?.call(participant) ?? false ? withoutCandidates(sdp) : sdp;

  Future<void> _dial(String participant) async {
    _dialing.add(participant);
    try {
      final pc = await _link(participant);
      await pc.setLocalDescription(await pc.createOffer());
      final offer = await gatheredDescription(pc);
      if (offer?.sdp case final sdp?) {
        await _host.signal(
          CallSignal(
            type: SignalType.offer,
            callId: _host.callId,
            to: participant,
            sdp: _sdp(participant, sdp),
          ),
        );
      }
    } finally {
      _dialing.remove(participant);
    }
  }

  Map<String, Object> get _config => {
    'iceServers': iceServers,
    'sdpSemantics': 'unified-plan',
  };

  /// Opens the link to [participant]; with [offer], as the answering side.
  Future<RTCPeerConnection> _link(String participant, {String? offer}) async {
    final pc = await connect(_config);
    _links[participant] = pc;
    _watch(pc, participant);
    _timers.remove(participant)?.cancel();
    _timers[participant] = Timer(connectTimeout, () {
      _timers.remove(participant);
      if (_links[participant] == pc && !_connected.contains(participant)) {
        unawaited(_linkFailed(participant));
      }
    });
    if (offer != null) {
      await pc.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
    }
    final stream = _host.outgoingStream;
    for (final track in _host.outgoingTracks) {
      // When answering, this takes over the offer's slot of the same kind.
      final sender = stream == null
          ? await pc.addTrack(track)
          : await pc.addTrack(track, stream);
      (_encrypted[pc] ??= {}).add(sender.senderId);
      await _host.crypto.encrypt(sender, _host.me, link: pc);
    }
    if (!_host.outgoingTracks.any((t) => t.kind == 'video')) {
      await _videoSlot(pc, answering: offer != null);
    }
    for (final transceiver in await pc.getTransceivers()) {
      await _host.crypto.decrypt(transceiver.receiver, participant, link: pc);
    }
    return pc;
  }

  /// Keeps a video slot so a later camera or screen needs no renegotiation.
  /// The answering side must reuse the offer's slot: one it adds itself stays
  /// out of the answer. The stream ties the video to the peer's audio.
  Future<void> _videoSlot(
    RTCPeerConnection pc, {
    required bool answering,
  }) async {
    final stream = _host.outgoingStream;
    if (!answering) {
      final (video, encrypted) = await addEncryptedVideo(
        pc,
        _host,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [?stream],
        ),
      );
      if (encrypted) (_encrypted[pc] ??= {}).add(video.sender.senderId);
      return;
    }
    if (await encryptOfferedVideo(pc, _host) case final sender?) {
      (_encrypted[pc] ??= {}).add(sender.senderId);
      return;
    }
    for (final transceiver in await pc.getTransceivers()) {
      if (transceiver.receiver.track?.kind != 'video') continue;
      await transceiver.setDirection(TransceiverDirection.SendRecv);
      if (stream != null) await transceiver.sender.setStreams([stream]);
      return;
    }
  }

  void _watch(RTCPeerConnection pc, String participant) {
    pc.onTrack = (event) {
      // Receivers created by the remote offer; on web the page hook already
      // attached them, since this callback runs too late there.
      final receiver = event.receiver;
      if (receiver != null && !receiversHandledByPage) {
        unawaited(_host.crypto.decrypt(receiver, participant, link: pc));
      }
      if (_links[participant] != pc) return;
      if (event.streams.firstOrNull case final stream?) {
        _direct[participant] = stream;
        _show(participant);
      }
    };
    pc.onConnectionState = (state) {
      // A replaced link can still report on its way out.
      if (_closed || _links[participant] != pc) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _timers.remove(participant)?.cancel();
          _failures.remove(participant);
          _relaySettled(participant);
          final changed =
              _connected.add(participant) | _failed.remove(participant);
          _show(participant);
          unawaited(_closeIncoming(participant));
          if (changed) _linksChanged();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          unawaited(_linkFailed(participant));
        default:
          break;
      }
      _publishState(participant, state.name);
    };
  }

  /// Closes the direct link, reports it failed, and lets the dialer try
  /// again after a backoff. A relay may carry the media meanwhile.
  Future<void> _linkFailed(String participant) async {
    final failures = (_failures[participant] ?? 0) + 1;
    _failures[participant] = failures;
    await _close(participant);
    final changed = _failed.add(participant);
    _show(participant);
    _publishState(participant);
    if (changed) _linksChanged();
    if (_closed || !_dials(participant)) return;
    _timers.remove(participant)?.cancel();
    _timers[participant] = Timer(redialDelay(failures), () {
      _timers.remove(participant);
      if (!_closed && !_links.containsKey(participant)) {
        unawaited(_dial(participant));
      }
    });
  }

  void _linksChanged() {
    _host.linksChanged();
    _reportsChanged();
  }

  /// Relays may have come or gone, for this device to serve or to wait on.
  void _reportsChanged() {
    _replan();
    if (_closed) return;
    for (final participant in [..._failed]) {
      final state = _stateOf(participant);
      if (_published[participant] != state) _setState(participant, state);
    }
  }

  /// Whether a relay for [participant]'s media is planned and still has
  /// time to connect.
  bool _relayPending(String participant) {
    if (_closed) return false;
    final reports = {..._reports, _host.me: linkReport};
    final via = relayFor(_host.me, participant, reports);
    if (via == null || _relayGaveUp[participant] == via) {
      _relayWait.remove(participant)?.timer.cancel();
      return false;
    }
    final wait = _relayWait[participant];
    if (wait?.via != via) {
      wait?.timer.cancel();
      _relayWait[participant] = (
        via: via,
        timer: Timer(connectTimeout, () {
          _relayWait.remove(participant);
          _relayGaveUp[participant] = via;
          if (!_closed) _publishState(participant);
        }),
      );
    }
    return true;
  }

  /// [participant]'s media arrives, so a relay wait is over.
  void _relaySettled(String participant) {
    _relayWait.remove(participant)?.timer.cancel();
    _relayGaveUp.remove(participant);
  }

  /// The direct stream once its link connected, else the relayed one, else
  /// the direct one still connecting.
  void _show(String participant) {
    final relayed = _incoming[participant]?.stream;
    final direct = _direct[participant];
    final stream = _connected.contains(participant)
        ? direct
        : relayed ?? direct;
    if (stream != null) _host.remoteStream(participant, stream);
  }

  void _publishState(String participant, [String? direct]) =>
      _setState(participant, _stateOf(participant, direct));

  void _setState(String participant, String state) {
    _published[participant] = state;
    _host.peerState(participant, state);
  }

  String _stateOf(String participant, [String? direct]) {
    final disconnected =
        direct ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected.name;
    return _connected.contains(participant) && !disconnected
        ? 'connected'
        : _incoming[participant]?.connected ?? false
        ? 'relayed'
        : _failed.contains(participant)
        ? _relayPending(participant)
              ? 'relaying'
              : 'failed'
        : direct ?? 'connecting';
  }

  /// Starts and stops the relay links this device serves.
  void _replan() {
    if (_closed) return;
    final reports = {..._reports, _host.me: linkReport};
    final jobs = relayJobs(_host.me, reports);
    for (final job in [..._serving.keys]) {
      if (!jobs.contains(job)) unawaited(_stopServing(job));
    }
    for (final job in jobs) {
      if (!_serving.containsKey(job)) unawaited(_serve(job));
    }
  }

  void _replanSoon() {
    _replanTimer?.cancel();
    _replanTimer = Timer(_relayRetry, _replan);
  }

  /// Sends [job]'s origin's media, as received on our direct link, to its
  /// target. The tracks arrive decrypted and leave encrypted again under
  /// the same call key.
  Future<void> _serve(RelayJob job) async {
    final source = _links[job.origin];
    final stream = _direct[job.origin];
    if (source == null || stream == null) {
      _replanSoon();
      return;
    }
    _serving[job] = null;
    _Outgoing? out;
    try {
      final relay = await connect(_config);
      if (_closed || !_serving.containsKey(job)) {
        await _closeQuietly(relay, 'relay ${job.origin} to ${job.target}');
        return;
      }
      out = _Outgoing(relay, blocked: relayBlocked?.call(job.target) ?? false);
      _serving[job] = out;
      final serving = out;
      var connected = false;
      void retry() {
        if (_serving[job] != serving) return;
        unawaited(_stopServing(job).then((_) => _replanSoon()));
      }

      // A lost relay_offer or relay_answer leaves the link in `new` for good.
      Timer(connectTimeout, () {
        if (!connected) retry();
      });
      relay.onConnectionState = (state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            connected = true;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            retry();
          default:
            break;
        }
      };
      for (final transceiver in await source.getTransceivers()) {
        final track = transceiver.receiver.track;
        if (track == null) continue;
        final MediaStreamTrack forwarded;
        if (cloneForwarded) {
          forwarded = await track.clone();
          serving.clones.add(forwarded);
          // Stopped while cloning: _stopServing missed this one.
          if (serving.stopped) {
            await _stopClones(serving);
            return;
          }
        } else {
          forwarded = track;
        }
        final sender = await relay.addTrack(forwarded, stream);
        await _host.crypto.encrypt(sender, _host.me, link: relay);
      }
      await relay.setLocalDescription(await relay.createOffer());
      final offer = await gatheredDescription(relay);
      if (offer?.sdp case final sdp? when !serving.stopped) {
        await _host.signal(
          CallSignal(
            type: SignalType.relayOffer,
            callId: _host.callId,
            to: job.target,
            origin: job.origin,
            sdp: out.blocked ? withoutCandidates(sdp) : sdp,
          ),
        );
      }
    } catch (e) {
      debugPrint('relay ${job.origin} to ${job.target}: $e');
      // Both null when connect threw.
      if (_serving[job] == out) {
        await _stopServing(job);
        _replanSoon();
      } else if (out != null) {
        await _stopClones(out);
      }
    }
  }

  Future<void> _stopServing(RelayJob job) async {
    if (!_serving.containsKey(job)) return;
    final out = _serving.remove(job);
    if (out == null) return;
    out.stopped = true;
    await _closeQuietly(out.pc, 'relay ${job.origin} to ${job.target}');
    await _stopClones(out);
  }

  Future<void> _stopClones(_Outgoing out) async {
    for (final track in [...out.clones]) {
      out.clones.remove(track);
      try {
        await track.stop();
      } catch (e) {
        debugPrint('stop relayed track: $e');
      }
    }
  }

  /// [origin]'s media through [via], replacing any earlier relay for it
  /// once the new link decrypts.
  Future<void> _acceptRelay(String via, String origin, String sdp) async {
    final previous = _incoming.remove(origin);
    try {
      await _openRelay(via, origin, sdp);
    } finally {
      if (previous != null) {
        await _closeQuietly(previous.pc, 'relay from ${previous.via}');
        if (!_closed) _publishState(origin);
      }
    }
  }

  Future<void> _openRelay(String via, String origin, String sdp) async {
    final pc = await connect(_config);
    if (_closed) {
      await _closeQuietly(pc, 'relay from $via');
      return;
    }
    final incoming = _Incoming(via, pc);
    _incoming[origin] = incoming;
    pc.onTrack = (event) {
      final receiver = event.receiver;
      if (receiver != null && !receiversHandledByPage) {
        unawaited(_host.crypto.decrypt(receiver, origin, link: pc));
      }
      if (_incoming[origin] != incoming) return;
      if (event.streams.firstOrNull case final stream?) {
        incoming.stream = stream;
        _show(origin);
      }
    };
    pc.onConnectionState = (state) {
      if (_closed || _incoming[origin] != incoming) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          incoming.connected = true;
          _relaySettled(origin);
          _show(origin);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (!incoming.connected) _relayGaveUp[origin] = via;
          unawaited(_closeIncoming(origin));
        default:
          break;
      }
      _publishState(origin);
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    for (final transceiver in await pc.getTransceivers()) {
      await _host.crypto.decrypt(transceiver.receiver, origin, link: pc);
    }
    await pc.setLocalDescription(await pc.createAnswer());
    final answer = await gatheredDescription(pc);
    if (answer?.sdp case final sdp?) {
      await _host.signal(
        CallSignal(
          type: SignalType.relayAnswer,
          callId: _host.callId,
          to: via,
          origin: origin,
          sdp: sdp,
        ),
      );
    }
  }

  Future<void> _closeIncoming(String origin) async {
    final incoming = _incoming.remove(origin);
    if (incoming == null) return;
    await _closeQuietly(incoming.pc, 'relay from ${incoming.via}');
    if (_closed) return;
    _show(origin);
    _publishState(origin);
  }

  @override
  Future<void> participantLeft(String participant) async {
    _timers.remove(participant)?.cancel();
    _failures.remove(participant);
    _reports.remove(participant);
    _relaySettled(participant);
    await _close(participant);
    await _closeIncoming(participant);
    final through = [
      for (final MapEntry(:key, :value) in _incoming.entries)
        if (value.via == participant) key,
    ];
    for (final origin in through) {
      await _closeIncoming(origin);
    }
    _failed.remove(participant);
    _published.remove(participant);
    _host.peerGone(participant);
    if (!_closed) _linksChanged();
  }

  Future<void> _close(String participant) async {
    final pc = _detach(participant);
    if (pc != null) await _closeQuietly(pc, 'link $participant');
  }

  /// Forgets the direct link to [participant] and returns it, still open.
  RTCPeerConnection? _detach(String participant) {
    _direct.remove(participant);
    final wasConnected = _connected.remove(participant);
    final pc = _links.remove(participant);
    if (wasConnected && !_closed) _linksChanged();
    return pc;
  }

  Future<void> _closeQuietly(RTCPeerConnection pc, String what) async {
    _encrypted.remove(pc);
    await closeLink(_host, pc, what);
  }

  @override
  Future<void> replaceAudio(MediaStreamTrack track) async {
    for (final pc in [..._links.values]) {
      for (final transceiver in await pc.getTransceivers()) {
        final sender = transceiver.sender;
        if (sender.track?.kind == 'audio') {
          await replaceTrackSettled(sender, track);
        }
      }
    }
  }

  @override
  Future<void> replaceVideo(MediaStreamTrack? track) async {
    for (final pc in [..._links.values]) {
      for (final transceiver in await pc.getTransceivers()) {
        final sender = transceiver.sender;
        final kind = sender.track?.kind ?? transceiver.receiver.track?.kind;
        if (kind != 'video') continue;
        await replaceTrackSettled(sender, track);
        if (track != null && (_encrypted[pc] ??= {}).add(sender.senderId)) {
          await _host.crypto.encrypt(sender, _host.me, link: pc);
        }
      }
    }
  }

  @override
  Future<Map<String, LinkStats>> stats() async {
    // Links can close while stats are awaited.
    final direct = Map.of(_links);
    final relayed = Map.of(_incoming);
    return {
      for (final participant in {...direct.keys, ...relayed.keys})
        participant: switch ((direct[participant], relayed[participant])) {
          (final pc?, _) when _connected.contains(participant) =>
            await linkStats(pc),
          (_, final relay?) when relay.connected => await linkStats(
            relay.pc,
            via: relay.via,
          ),
          (final pc?, _) => await linkStats(pc),
          (_, final relay?) => await linkStats(relay.pc, via: relay.via),
          (null, null) => const LinkStats(state: 'closed'),
        },
    };
  }

  @override
  Future<void> close() async {
    _closed = true;
    _replanTimer?.cancel();
    for (final timer in [
      ..._timers.values,
      for (final wait in _relayWait.values) wait.timer,
    ]) {
      timer.cancel();
    }
    _timers.clear();
    _relayWait.clear();
    for (final job in [..._serving.keys]) {
      await _stopServing(job);
    }
    for (final origin in [..._incoming.keys]) {
      await _closeIncoming(origin);
    }
    for (final participant in [..._links.keys]) {
      await _close(participant);
    }
  }
}
