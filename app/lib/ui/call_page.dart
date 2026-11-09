import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ndk/shared/nips/nip19/nip19.dart';

import '../core/calls/call_quality.dart';
import '../core/calls/calls.dart';
import '../core/calls/group_call.dart';
import '../core/calls/screen_capture.dart';
import '../core/session.dart';
import '../core/sounds.dart';
import 'audio_settings.dart';
import 'fullscreen.dart';
import 'group_conversation.dart';
import 'manga.dart';
import 'people.dart';
import 'ring_tone.dart';
import 'server_dialog.dart';
import 'theme.dart';

bool get _desktop =>
    !kIsWeb &&
    const {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

/// How many call pages are showing or opening; the call bar hides then.
final callPageOpen = ValueNotifier<int>(0);

/// Joins the group's call, or returns to it, and shows it. Closing the page
/// keeps the call going; hanging up ends it.
Future<void> openCall(
  BuildContext context,
  Session session,
  String groupId,
) async {
  final calls = session.calls;
  if (calls == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final name = session.groups?.group(groupId)?.name ?? 'Call';
  // Counted from before the join, so the bar never flashes in between.
  callPageOpen.value += 1;
  // The page shows at once; joining can take seconds (microphone, servers).
  final joining = calls.join(groupId);
  var showing = true;
  unawaited(
    joining.then(
      (_) {
        if (calls.serverProblem case final problem?) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'No call server answered, calling directly. $problem',
              ),
            ),
          );
        }
      },
      onError: (Object e) {
        if (showing) navigator.pop();
        messenger.showSnackBar(SnackBar(content: Text('Could not join: $e')));
      },
    ),
  );
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => FutureBuilder(
          future: joining,
          builder: (context, snapshot) => switch (snapshot.data) {
            final call? => CallPage(session: session, call: call),
            null => _Joining(name: name),
          },
        ),
      ),
    );
  } finally {
    showing = false;
    callPageOpen.value -= 1;
  }
}

class _Joining extends StatelessWidget {
  const _Joining({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(name.toUpperCase())),
    body: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Joining the call…'),
        ],
      ),
    ),
  );
}

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.session, required this.call});

  final Session session;
  final GroupCall call;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  /// Wide layouts show the chat beside the tiles unless closed.
  bool _chatOpen = true;

  static const _sideChatFrom = 900.0;

  Session get session => widget.session;
  GroupCall get call => widget.call;

  /// The caller hears this until someone answers, for at most 15 s.
  late final _ringback = RingTone(
    Sound.ringback,
    () => session.audio.current.toneFor(Sound.ringback),
  );
  Timer? _ringbackLimit;

  final _quality = ValueNotifier<Map<String, LinkQuality>>(const {});
  Timer? _qualityTimer;

  /// The tile shown big for this viewer only: a pubkey, ours included.
  final _highlight = ValueNotifier<String?>(null);

  /// Other group members, listed in the people sheet to ring them.
  List<String> _members = const [];
  final Map<String, DateTime> _rungAt = {};
  Timer? _ringRefresh;

  /// Bumped when members or rings change, for the people sheet.
  final _people = ValueNotifier<int>(0);

  void _peopleChanged() {
    if (mounted) _people.value++;
  }

  List<String> get _absent => [
    for (final m in _members)
      if (!call.participants.containsKey(m)) m,
  ];

  bool _ringing(String pubkey) =>
      _rungAt[pubkey]?.isAfter(DateTime.now().subtract(ringFor)) ?? false;

  Future<void> _loadMembers({required bool started}) async {
    final members = await session.groups?.members(call.groupId);
    if (members == null || !mounted) return;
    final now = DateTime.now();
    _members = [
      for (final m in members)
        if (m != session.identity.publicKey) m,
    ];
    // Starting a call rings everyone else.
    if (started) {
      for (final m in _members) {
        _rungAt[m] = now;
      }
      _refreshWhenRingsEnd();
    }
    _peopleChanged();
  }

  void _refreshWhenRingsEnd() {
    _ringRefresh?.cancel();
    _ringRefresh = Timer(
      ringFor + const Duration(milliseconds: 200),
      _peopleChanged,
    );
  }

  /// Rings [pubkey], or everyone not in the call.
  Future<void> _ring([String? pubkey]) async {
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    for (final m in pubkey == null ? _absent : [pubkey]) {
      _rungAt[m] = now;
    }
    _peopleChanged();
    _refreshWhenRingsEnd();
    try {
      await session.ring(call.groupId, pubkey: pubkey);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not ring: $e')));
    }
  }

  Future<void> _showPeople() => showPanelSheet<void>(
    context,
    builder: (_) => ListenableBuilder(
      listenable: Listenable.merge([call, _people]),
      builder: (context, _) => _PeopleSheet(
        session: session,
        call: call,
        absent: _absent,
        ringing: _ringing,
        onRing: _ring,
      ),
    ),
  );

  Future<void> _measureQuality() async {
    if (call.closed) return;
    try {
      final quality = await call.quality();
      if (mounted) _quality.value = quality;
    } catch (e) {
      debugPrint('call quality: $e');
    }
  }

  /// A hotkey or the call bar can end the call while this page shows.
  void _closeWhenOver() {
    if (!call.closed || !mounted) return;
    call.removeListener(_closeWhenOver);
    Navigator.of(context).maybePop();
  }

  /// Closes the page at once; the call ends in the background.
  void _hangUp() {
    unawaited(session.calls?.leave());
    Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    call.addListener(_closeWhenOver);
    call.addListener(_syncRingback);
    final started = session.calls?.dialing ?? false;
    _syncRingback();
    unawaited(_loadMembers(started: started));
    _ringbackLimit = Timer(const Duration(seconds: 15), _endRingback);
    _qualityTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_measureQuality()),
    );
  }

  @override
  void dispose() {
    call.removeListener(_closeWhenOver);
    _endRingback();
    _qualityTimer?.cancel();
    _ringRefresh?.cancel();
    _quality.dispose();
    _highlight.dispose();
    _people.dispose();
    super.dispose();
  }

  void _syncRingback() {
    if (session.calls?.dialing ?? false) {
      _ringback.start();
    } else {
      _endRingback();
    }
  }

  /// Once stopped it stays stopped, even if everyone leaves again.
  void _endRingback() {
    call.removeListener(_syncRingback);
    _ringbackLimit?.cancel();
    _ringback.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _sideChatFrom;
        return ListenableBuilder(
          listenable: call,
          builder: (context, _) {
            final name = session.groups?.group(call.groupId)?.name ?? 'Call';
            final stage = Column(
              children: [
                if (call.switching)
                  const _Notice('Switching how the call travels…'),
                if (call.switchProblem case final problem?)
                  _Notice('Could not switch: $problem'),
                if (call.videoCapped)
                  const _Notice(
                    'Big call: cameras pause on mesh. A server keeps them on.',
                  ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_quality, _highlight]),
                    builder: (context, _) => _Tiles(
                      session: session,
                      call: call,
                      quality: _quality.value,
                      highlight: _highlight,
                    ),
                  ),
                ),
                _Controls(call: call, onHangUp: _hangUp),
              ],
            );
            return Scaffold(
              appBar: AppBar(
                title: Text(name.toUpperCase()),
                actions: [
                  IconButton(
                    tooltip: 'People: ring the ones not here',
                    icon: const Icon(Icons.group_outlined),
                    onPressed: _showPeople,
                  ),
                  _QualityButton(session: session, quality: _quality),
                  IconButton(
                    tooltip: 'Audio settings',
                    icon: const Icon(Icons.settings_voice_outlined),
                    onPressed: () => showAudioSettings(context, session),
                  ),
                  _ModeSwitch(session: session, call: call),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: wide && _chatOpen ? 'Hide chat' : 'Chat',
                    isSelected: wide && _chatOpen,
                    icon: const Icon(Icons.chat_bubble_outline),
                    selectedIcon: const Icon(Icons.chat_bubble),
                    onPressed: wide
                        ? () => setState(() => _chatOpen = !_chatOpen)
                        : () => _showChat(context),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              body: wide && _chatOpen
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: stage),
                        const VerticalDivider(
                          width: MangaShape.stroke,
                          thickness: MangaShape.stroke,
                          color: MangaColors.ink,
                        ),
                        SizedBox(
                          width: 360,
                          child: GroupConversation(
                            session: session,
                            groupId: call.groupId,
                            padding: const EdgeInsets.all(16),
                          ),
                        ),
                      ],
                    )
                  : stage,
            );
          },
        );
      },
    );
  }

  Future<void> _showChat(BuildContext context) => showPanelSheet<void>(
    context,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: GroupConversation(
          session: session,
          groupId: call.groupId,
          padding: const EdgeInsets.all(16),
        ),
      ),
    ),
  );
}

/// The mode badge; tapping it explains how the call is protected and
/// carried, and moves everyone to another mode.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.session, required this.call});

  final Session session;
  final GroupCall call;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Encryption and how the call travels',
    child: InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showPanelSheet<void>(
        context,
        builder: (_) => _CallInfoSheet(session: session, call: call),
      ),
      child: _ModeBadge(mode: call.mode),
    ),
  );
}

/// What each call mode is, for the info sheet.
const _modeInfo = {
  'mesh': (
    title: 'Direct (mesh)',
    about:
        'Every member connects to every other. No server in between, so '
        'nothing to set up.',
    limits:
        'Each member uploads to everyone: audio is fine for about 15 '
        'people; cameras pause above 4 others.',
  ),
  'server': (
    title: 'Call server',
    about:
        'Everyone sends one stream to a Moranduba server (SFU) that '
        'forwards it. It sees only encrypted frames and who is connected.',
    limits:
        "Scales to the server's bandwidth. Set one up, or use one someone "
        'shares, in Call server settings.',
  ),
  'host_peer': (
    title: "A member's computer",
    about:
        'A member running Moranduba on a desktop hosts the call server '
        'for the group while the app is open.',
    limits:
        'The host needs good upload (about 20 Mbps for 15 people) and the '
        'desktop app open.',
  ),
};

class _CallInfoSheet extends StatelessWidget {
  const _CallInfoSheet({required this.session, required this.call});

  final Session session;
  final GroupCall call;

  bool _available(String mode) => switch (mode) {
    'server' => session.serverOf(call.groupId) != null,
    'host_peer' => session.hostsOf(call.groupId).isNotEmpty,
    _ => true,
  };

  /// Opens the mode's settings when it has any, then moves everyone to it
  /// once it can carry the call.
  Future<void> _select(BuildContext context, String mode) async {
    if (mode != 'mesh') {
      await showDialog<void>(
        context: context,
        builder: (_) => ServerDialog(session: session, groupId: call.groupId),
      );
    }
    if (mode == call.mode || !_available(mode)) return;
    if (!call.canSwitch || call.switching) return;
    await call.switchMode(mode);
  }

  String _hint(String mode) {
    if (mode == call.mode) return 'IN USE';
    if (!_available(mode)) return 'Set up';
    if (!call.canSwitch || call.switching) return '';
    return 'Switch everyone';
  }

  String _unavailable(String mode) => switch (mode) {
    'server' => 'No call server set for this group. Tap to add one.',
    'host_peer' =>
      'Nobody hosts calls for this group. Tap to host from '
          'a desktop.',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final sfu = call.sfu;
        return SafeArea(
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('END-TO-END ENCRYPTED', style: text.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'Audio and video are encrypted on your device with a '
                      'key only this group has (exported from its MLS '
                      'group, epoch ${call.keyEpoch}). Relays and servers '
                      'forward ciphertext; when members join or leave, the '
                      'key changes.',
                    ),
                    const SizedBox(height: 16),
                    Text('HOW IT TRAVELS', style: text.titleMedium),
                    const SizedBox(height: 8),
                    for (final mode in _modeInfo.keys)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            borderRadius: MangaShape.borderRadius,
                            onTap: mode == call.mode && mode == 'mesh'
                                ? null
                                : () => unawaited(_select(context, mode)),
                            child: Panel(
                              color: mode == call.mode
                                  ? MangaColors.tone
                                  : MangaColors.paper,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _modeInfo[mode]!.title,
                                          style: text.titleSmall,
                                        ),
                                      ),
                                      Text(_hint(mode), style: text.labelLarge),
                                      if (mode != 'mesh') ...[
                                        const SizedBox(width: 4),
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(_modeInfo[mode]!.about),
                                  const SizedBox(height: 4),
                                  Text(
                                    _available(mode)
                                        ? _modeInfo[mode]!.limits
                                        : _unavailable(mode),
                                    style: text.bodySmall,
                                  ),
                                  if (mode == call.mode && sfu != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Server: ${Nip19.encodePubKey(sfu)}',
                                      style: monoStyle.copyWith(fontSize: 11),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (call.switching) const Text('Switching…'),
                    if (call.switchProblem case final problem?)
                      Text('Last switch failed: $problem'),
                    const SizedBox(height: 8),
                    Text('CONNECTIONS', style: text.titleMedium),
                    const SizedBox(height: 4),
                    if (call.participants.isEmpty)
                      const Text('Nobody else yet.')
                    else
                      for (final p in call.participants.values)
                        Text('${session.displayName(p.pubkey)}: ${p.state}'),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.dns_outlined, size: 18),
                          label: const Text('Call server settings'),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => ServerDialog(
                              session: session,
                              groupId: call.groupId,
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(
                            Icons.settings_voice_outlined,
                            size: 18,
                          ),
                          label: const Text('Audio settings'),
                          onPressed: () => showAudioSettings(context, session),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: MangaColors.charcoal,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      'E2EE · ${mode.replaceAll('_', ' ').toUpperCase()}',
      style: const TextStyle(
        color: MangaColors.paper,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: .5,
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Panel(toned: true, child: Text(text)),
  );
}

class _Tiles extends StatelessWidget {
  const _Tiles({
    required this.session,
    required this.call,
    required this.quality,
    required this.highlight,
  });

  final Session session;
  final GroupCall call;
  final Map<String, LinkQuality> quality;
  final ValueNotifier<String?> highlight;

  void _toggle(String pubkey) =>
      highlight.value = highlight.value == pubkey ? null : pubkey;

  @override
  Widget build(BuildContext context) {
    final me = session.identity.publicKey;
    final others = call.participants.values.toList();
    final showMine = call.cameraOn || call.sharing;
    final tiles = <(String, Widget)>[
      (
        me,
        _Tile(
          label: 'You',
          avatar: PersonAvatar(session: session, pubkey: me, size: 96),
          renderer: call.localRenderer,
          showVideo: showMine,
          muted: !call.micOn,
          mirror: !call.sharing,
          note: call.sharing ? 'Sharing screen' : null,
          highlighted: highlight.value == me,
          onHighlight: () => _toggle(me),
          onFullscreen: showMine
              ? () => openFullscreen(
                  context,
                  call.localRenderer,
                  label: 'You',
                  mirror: !call.sharing,
                )
              : null,
        ),
      ),
      for (final p in others)
        (
          p.pubkey,
          _Tile(
            label: session.displayName(p.pubkey),
            avatar: PersonAvatar(session: session, pubkey: p.pubkey, size: 96),
            renderer: p.renderer,
            showVideo: (p.media.video || p.media.screen) && !p.videoHidden,
            muted: !p.media.audio || p.mutedForMe,
            quality: quality[p.pubkey]?.level,
            onTap: () => _showPersonControls(
              context,
              session,
              call,
              p.pubkey,
              highlight,
            ),
            note: switch (p.state) {
              'connected' => p.media.screen ? 'Sharing screen' : null,
              final state => state == 'new' ? 'Connecting…' : state,
            },
            highlighted: highlight.value == p.pubkey,
            onHighlight: () => _toggle(p.pubkey),
            onFullscreen:
                (p.media.video || p.media.screen) &&
                    !p.videoHidden &&
                    p.renderer != null
                ? () => openFullscreen(
                    context,
                    p.renderer,
                    label: session.displayName(p.pubkey),
                  )
                : null,
          ),
        ),
    ];
    if (others.isEmpty) {
      tiles.add(('waiting', const _Waiting()));
    }
    final big = tiles.where((t) => t.$1 == highlight.value).firstOrNull;
    if (big != null) {
      final rest = [
        for (final t in tiles)
          if (t != big) t.$2,
      ];
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(child: big.$2),
            if (rest.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: rest.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => SizedBox(width: 160, child: rest[i]),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (tiles.length) {
          1 => 1,
          2 => constraints.maxWidth > constraints.maxHeight ? 2 : 1,
          <= 4 => 2,
          <= 9 => 3,
          _ => 4,
        };
        return GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 4 / 3,
          children: [for (final t in tiles) t.$2],
        );
      },
    );
  }
}

/// Fills the window with [renderer], and the screen on web; Esc or the
/// close button leaves.
Future<void> openFullscreen(
  BuildContext context,
  RTCVideoRenderer? renderer, {
  required String label,
  bool mirror = false,
}) async {
  if (renderer == null) return;
  enterBrowserFullscreen();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          _FullscreenVideo(renderer: renderer, label: label, mirror: mirror),
    ),
  );
  exitBrowserFullscreen();
}

class _FullscreenVideo extends StatelessWidget {
  const _FullscreenVideo({
    required this.renderer,
    required this.label,
    required this.mirror,
  });

  final RTCVideoRenderer renderer;
  final String label;
  final bool mirror;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).maybePop(),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(
              renderer,
              mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
            Positioned(left: 16, bottom: 16, child: _Label(label)),
            Positioned(
              top: 16,
              right: 16,
              child: _TileButton(
                icon: Icons.fullscreen_exit,
                tooltip: 'Exit full screen (Esc)',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TileButton extends StatelessWidget {
  const _TileButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: MangaColors.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: const BorderSide(width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18),
        ),
      ),
    ),
  );
}

/// Everyone in the group: who is in the call, and a ring for the rest.
class _PeopleSheet extends StatelessWidget {
  const _PeopleSheet({
    required this.session,
    required this.call,
    required this.absent,
    required this.ringing,
    required this.onRing,
  });

  final Session session;
  final GroupCall call;
  final List<String> absent;
  final bool Function(String pubkey) ringing;
  final void Function([String? pubkey]) onRing;

  Widget _person(String pubkey, {required String status, Widget? action}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: PersonAvatar(session: session, pubkey: pubkey, size: 36),
        title: Text(session.displayName(pubkey)),
        subtitle: Text(status),
        trailing: action,
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final me = session.identity.publicKey;
    return SafeArea(
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('PEOPLE', style: text.headlineSmall),
                const SizedBox(height: 12),
                Text('IN THE CALL', style: text.titleSmall),
                _person(me, status: 'Here'),
                for (final p in call.participants.values)
                  _person(p.pubkey, status: p.state),
                if (absent.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: Text('NOT HERE', style: text.titleSmall)),
                      TextButton.icon(
                        icon: const Icon(Icons.ring_volume_outlined, size: 18),
                        label: const Text('Ring everyone'),
                        onPressed: absent.every(ringing) ? null : onRing,
                      ),
                    ],
                  ),
                  for (final pubkey in absent)
                    ringing(pubkey)
                        ? _person(
                            pubkey,
                            status: 'Ringing…',
                            action: const Icon(Icons.ring_volume),
                          )
                        : _person(
                            pubkey,
                            status: 'Not in the call',
                            action: OutlinedButton.icon(
                              icon: const Icon(
                                Icons.ring_volume_outlined,
                                size: 18,
                              ),
                              label: const Text('Ring'),
                              onPressed: () => onRing(pubkey),
                            ),
                          ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const Panel(
    toned: true,
    child: Center(
      child: Text(
        'Waiting for the others to join…',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.avatar,
    required this.renderer,
    required this.showVideo,
    required this.muted,
    this.mirror = false,
    this.note,
    this.onTap,
    this.quality,
    this.highlighted = false,
    this.onHighlight,
    this.onFullscreen,
  });

  final String label;
  final Widget avatar;

  /// Opens per-person controls; null for our own tile.
  final VoidCallback? onTap;
  final RTCVideoRenderer? renderer;
  final bool showVideo;
  final bool muted;
  final bool mirror;
  final String? note;

  /// Shown only when the link struggles.
  final QualityLevel? quality;
  final bool highlighted;
  final VoidCallback? onHighlight;

  /// Null when there is no video to show.
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    final video = renderer;
    final quality = this.quality;
    final tile = DecoratedBox(
      decoration: BoxDecoration(
        color: MangaColors.charcoal,
        borderRadius: MangaShape.borderRadius,
        border: Border.all(width: MangaShape.stroke),
        boxShadow: MangaShape.panelShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          MangaShape.radius - MangaShape.stroke,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video != null)
              Offstage(
                offstage: !showVideo,
                child: RTCVideoView(
                  video,
                  mirror: mirror,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            if (!showVideo)
              Screentone(
                color: const Color(0xFF444444),
                child: Center(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: MangaColors.paper,
                      shape: BoxShape.circle,
                    ),
                    child: avatar,
                  ),
                ),
              ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  if (onHighlight case final toggle?)
                    _TileButton(
                      icon: highlighted
                          ? Icons.close_fullscreen
                          : Icons.open_in_full,
                      tooltip: highlighted ? 'Back to the grid' : 'Highlight',
                      onPressed: toggle,
                    ),
                  if (onFullscreen case final full?) ...[
                    const SizedBox(width: 6),
                    _TileButton(
                      icon: Icons.fullscreen,
                      tooltip: 'Full screen',
                      onPressed: full,
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              right: 8,
              child: Row(
                children: [
                  _Label(label),
                  if (muted) ...[
                    const SizedBox(width: 6),
                    const _Label.icon(Icons.mic_off),
                  ],
                  if (quality == QualityLevel.fair ||
                      quality == QualityLevel.poor) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Weak connection',
                      child: _Label.icon(qualityIcon(quality)),
                    ),
                  ],
                  const Spacer(),
                  if (note case final text?) _Label(text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final tap = onTap;
    if (tap == null) return tile;
    return Tooltip(
      message: 'Volume, mute and video for $label',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: tap, child: tile),
      ),
    );
  }
}

/// Mute, volume and video for one person, for us only.
Future<void> _showPersonControls(
  BuildContext context,
  Session session,
  GroupCall call,
  String pubkey,
  ValueNotifier<String?> highlight,
) => showPanelSheet<void>(
  context,
  builder: (_) => ListenableBuilder(
    listenable: Listenable.merge([call, highlight]),
    builder: (context, _) {
      final p = call.participants[pubkey];
      if (p == null) return const SizedBox.shrink();
      return SafeArea(
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    session.displayName(pubkey).toUpperCase(),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text('Only you hear and see these changes.'),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('Mute for me'),
                    value: p.mutedForMe,
                    onChanged: (on) => call.setMutedForMe(pubkey, on),
                  ),
                  ListTile(
                    title: const Text('Volume'),
                    subtitle: Slider(
                      value: p.volume,
                      max: 2,
                      divisions: 40,
                      label: '${(p.volume * 100).round()}%',
                      onChanged: p.mutedForMe
                          ? null
                          : (v) => call.setVolume(pubkey, v),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Highlight: show them big'),
                    value: highlight.value == pubkey,
                    onChanged: (on) => highlight.value = on ? pubkey : null,
                  ),
                  SwitchListTile(
                    title: const Text('Hide video and screen share'),
                    value: p.videoHidden,
                    onChanged: (on) => call.setVideoHidden(pubkey, on),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  ),
);

class _Label extends StatelessWidget {
  const _Label(String this.text) : icon = null;

  const _Label.icon(IconData this.icon) : text = null;

  final String? text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: MangaColors.paper,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(width: 1.5),
    ),
    child: switch ((text, icon)) {
      (final String text, _) => Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      (_, final IconData icon) => Icon(icon, size: 14),
      _ => const SizedBox.shrink(),
    },
  );
}

class _Controls extends StatelessWidget {
  const _Controls({required this.call, required this.onHangUp});

  final GroupCall call;
  final VoidCallback onHangUp;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(width: MangaShape.stroke)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        // Matches the chat composer's height, so the side chat lines up.
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            _RoundButton(
              tooltip: call.micOn ? 'Mute' : 'Unmute',
              icon: call.micOn ? Icons.mic : Icons.mic_off,
              active: call.micOn,
              onPressed: () => call.setMic(!call.micOn),
            ),
            _RoundButton(
              tooltip: call.deafened ? 'Undeafen' : 'Deafen',
              icon: call.deafened ? Icons.headset_off : Icons.headset,
              active: !call.deafened,
              onPressed: () => call.setDeafened(!call.deafened),
            ),
            _RoundButton(
              tooltip: call.cameraOn ? 'Stop camera' : 'Start camera',
              icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
              active: call.cameraOn,
              onPressed: () => _toggleCamera(context, call),
            ),
            _RoundButton(
              tooltip: call.sharing ? 'Stop sharing' : 'Share screen',
              icon: call.sharing
                  ? Icons.stop_screen_share_outlined
                  : Icons.screen_share_outlined,
              active: call.sharing,
              onPressed: () =>
                  call.sharing ? call.stopSharing() : _share(context, call),
            ),
            _RoundButton(
              tooltip: 'Hang up',
              icon: Icons.call_end,
              danger: true,
              onPressed: onHangUp,
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _toggleCamera(BuildContext context, GroupCall call) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await call.setCamera(!call.cameraOn);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Camera unavailable: $e')));
  }
}

Future<void> _share(BuildContext context, GroupCall call) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final MediaStream? stream;
    if (!_desktop) {
      stream = await captureScreen();
    } else {
      final source = await showDialog<DesktopCapturerSource>(
        context: context,
        builder: (_) => const _ScreenPicker(),
      );
      stream = source == null
          ? null
          : await navigator.mediaDevices.getDisplayMedia({
              'video': {
                'deviceId': {'exact': source.id},
                'mandatory': {'frameRate': 15.0},
              },
            });
    }
    if (stream != null) await call.shareScreen(stream);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not share: $e')));
  }
}

class _ScreenPicker extends StatefulWidget {
  const _ScreenPicker();

  @override
  State<_ScreenPicker> createState() => _ScreenPickerState();
}

class _ScreenPickerState extends State<_ScreenPicker> {
  late final Future<List<DesktopCapturerSource>> _sources = desktopCapturer
      .getSources(
        types: [SourceType.Screen, SourceType.Window],
        thumbnailSize: ThumbnailSize(320, 180),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('SHARE WHAT?'),
    content: SizedBox(
      width: 560,
      height: 380,
      child: FutureBuilder(
        future: _sources,
        builder: (context, snapshot) {
          final sources = snapshot.data;
          if (sources == null) {
            return snapshot.hasError
                ? Text('Screen capture unavailable: ${snapshot.error}')
                : const Center(child: Skeleton(width: 200));
          }
          return GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 16 / 11,
            children: [
              for (final source in sources)
                InkWell(
                  onTap: () => Navigator.of(context).pop(source),
                  child: Panel(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        Expanded(
                          child: switch (source.thumbnail) {
                            final Uint8List bytes => Image.memory(bytes),
                            _ => const Icon(Icons.desktop_windows_outlined),
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fill = danger
        ? MangaColors.error
        : active
        ? MangaColors.charcoal
        : MangaColors.paper;
    final ink = danger || active ? MangaColors.paper : MangaColors.ink;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill,
        shape: const CircleBorder(side: BorderSide(width: MangaShape.stroke)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(dimension: 56, child: Icon(icon, color: ink)),
        ),
      ),
    );
  }
}

IconData qualityIcon(QualityLevel? level) => switch (level) {
  QualityLevel.good => Icons.signal_cellular_alt,
  QualityLevel.fair => Icons.signal_cellular_alt_2_bar,
  QualityLevel.poor => Icons.signal_cellular_alt_1_bar,
  QualityLevel.unknown || null => Icons.signal_cellular_null,
};

String _qualityName(QualityLevel level) => switch (level) {
  QualityLevel.good => 'good',
  QualityLevel.fair => 'fair',
  QualityLevel.poor => 'poor',
  QualityLevel.unknown => 'measuring…',
};

/// Signal bars for the worst link; tapping lists every link's numbers.
class _QualityButton extends StatelessWidget {
  const _QualityButton({required this.session, required this.quality});

  final Session session;
  final ValueListenable<Map<String, LinkQuality>> quality;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: quality,
    builder: (context, links, _) {
      final worst = worstOf(links.values);
      return IconButton(
        tooltip: 'Connection: ${_qualityName(worst)}',
        icon: Icon(
          qualityIcon(worst),
          color: worst == QualityLevel.poor ? MangaColors.error : null,
        ),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('CONNECTION'),
            content: SizedBox(
              width: 420,
              child: ValueListenableBuilder(
                valueListenable: quality,
                builder: (context, links, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (links.isEmpty) const Text('Nobody else is here yet.'),
                    for (final MapEntry(key: pubkey, value: link)
                        in links.entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(qualityIcon(link.level)),
                        title: Text(
                          '${session.displayName(pubkey)}: '
                          '${_qualityName(link.level)}',
                        ),
                        subtitle: Text(_numbers(link), style: monoStyle),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    },
  );

  static String _numbers(LinkQuality link) => [
    if (link.roundTrip case final rtt?) 'delay ${rtt.inMilliseconds} ms',
    if (link.loss case final loss?) 'loss ${(loss * 100).toStringAsFixed(1)}%',
    if (link.jitter case final jitter?) 'jitter ${jitter.inMilliseconds} ms',
  ].join(' · ');
}
