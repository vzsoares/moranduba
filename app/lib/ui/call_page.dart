import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/calls/group_call.dart';
import '../core/session.dart';
import 'manga.dart';
import 'people.dart';
import 'theme.dart';

bool get _desktop =>
    !kIsWeb &&
    const {
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

bool get canShareScreen => kIsWeb || _desktop;

/// Joins the group's call and shows it; leaving the page hangs up.
Future<void> openCall(
  BuildContext context,
  Session session,
  String groupId,
) async {
  final calls = session.calls;
  if (calls == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    final call = await calls.join(groupId);
    if (calls.serverProblem case final problem?) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Call server unavailable, calling directly. $problem'),
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
  }
}

class CallPage extends StatelessWidget {
  const CallPage({super.key, required this.session, required this.call});

  final Session session;
  final GroupCall call;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(session.calls?.leave());
      },
      child: ListenableBuilder(
        listenable: call,
        builder: (context, _) {
          final name = session.groups?.group(call.groupId)?.name ?? 'Call';
          return Scaffold(
            appBar: AppBar(
              title: Text(name.toUpperCase()),
              actions: [
                _ModeBadge(mode: call.mode),
                const SizedBox(width: 16),
              ],
            ),
            body: Column(
              children: [
                if (call.videoCapped)
                  const _Notice(
                    'Big call: cameras pause on mesh. A server keeps them on.',
                  ),
                Expanded(
                  child: _Tiles(session: session, call: call),
                ),
                _Controls(call: call),
              ],
            ),
          );
        },
      ),
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
  const _Controls({required this.call});

  final GroupCall call;

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
            if (call.hasCamera)
              _RoundButton(
                tooltip: call.cameraOn ? 'Stop camera' : 'Start camera',
                icon: call.cameraOn ? Icons.videocam : Icons.videocam_off,
                active: call.cameraOn,
                onPressed: () => call.setCamera(!call.cameraOn),
              ),
            if (canShareScreen)
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
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _share(BuildContext context, GroupCall call) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final MediaStream? stream;
    if (kIsWeb) {
      stream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
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
