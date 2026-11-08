import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/calls/group_call.dart';
import '../core/calls/screen_capture.dart';
import '../core/session.dart';
import 'group_conversation.dart';
import 'manga.dart';
import 'people.dart';
import 'ring_tone.dart';
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
  // Counted from before the join, so the bar never flashes in between.
  callPageOpen.value += 1;
  try {
    final call = await calls.join(groupId);
    if (calls.serverProblem case final problem?) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No call server answered, calling directly. $problem'),
        ),
      );
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CallPage(session: session, call: call),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not join: $e')));
  } finally {
    callPageOpen.value -= 1;
  }
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
  final _ringback = RingTone.ringback();
  Timer? _ringbackLimit;

  void _hangUp() {
    unawaited(session.calls?.leave());
    Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    call.addListener(_syncRingback);
    _syncRingback();
    _ringbackLimit = Timer(const Duration(seconds: 15), _endRingback);
  }

  @override
  void dispose() {
    _endRingback();
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
                  child: _Tiles(session: session, call: call),
                ),
                _Controls(call: call, onHangUp: _hangUp),
              ],
            );
            return Scaffold(
              appBar: AppBar(
                title: Text(name.toUpperCase()),
                actions: [
                  _ModeSwitch(
                    call: call,
                    modes: [
                      'mesh',
                      if (session.serverOf(call.groupId) != null) 'server',
                      if (session.hostsOf(call.groupId).isNotEmpty) 'host_peer',
                    ],
                  ),
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

/// The mode badge; a menu to move the whole call to another mode.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.call, required this.modes});

  final GroupCall call;

  /// Modes this group can use.
  final List<String> modes;

  static const _labels = {
    'mesh': 'Switch everyone to direct (mesh)',
    'server': 'Switch everyone to the call server',
    'host_peer': "Switch everyone to a member's computer",
  };

  @override
  Widget build(BuildContext context) {
    final badge = _ModeBadge(mode: call.mode);
    final targets = modes.where((m) => m != call.mode).toList();
    if (!call.canSwitch || call.switching || targets.isEmpty) return badge;
    return PopupMenuButton<String>(
      tooltip: 'How the call travels',
      onSelected: (mode) => unawaited(call.switchMode(mode)),
      itemBuilder: (_) => [
        for (final mode in targets)
          PopupMenuItem(value: mode, child: Text(_labels[mode] ?? mode)),
      ],
      child: badge,
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
  const _Tiles({required this.session, required this.call});

  final Session session;
  final GroupCall call;

  @override
  Widget build(BuildContext context) {
    final others = call.participants.values.toList();
    final tiles = <Widget>[
      _Tile(
        label: 'You',
        avatar: PersonAvatar(
          session: session,
          pubkey: session.identity.publicKey,
          size: 96,
        ),
        renderer: call.localRenderer,
        showVideo: call.cameraOn || call.sharing,
        muted: !call.micOn,
        mirror: !call.sharing,
        note: call.sharing ? 'Sharing screen' : null,
      ),
      for (final p in others)
        _Tile(
          label: session.displayName(p.pubkey),
          avatar: PersonAvatar(session: session, pubkey: p.pubkey, size: 96),
          renderer: p.renderer,
          showVideo: p.media.video || p.media.screen,
          muted: !p.media.audio,
          note: switch (p.state) {
            'connected' => p.media.screen ? 'Sharing screen' : null,
            final state => state == 'new' ? 'Connecting…' : state,
          },
        ),
    ];
    if (others.isEmpty) {
      tiles.add(const _Waiting());
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
          children: tiles,
        );
      },
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
  });

  final String label;
  final Widget avatar;
  final RTCVideoRenderer? renderer;
  final bool showVideo;
  final bool muted;
  final bool mirror;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final video = renderer;
    return DecoratedBox(
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
                  const Spacer(),
                  if (note case final text?) _Label(text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
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
