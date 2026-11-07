import 'dart:async';

import 'package:flutter/material.dart';

import '../core/calls/calls.dart';
import '../core/expiry.dart';
import '../core/session.dart';
import 'app_controller.dart';
import 'call_page.dart';
import 'manga.dart';
import 'notifications/notifications.dart';
import 'people.dart';
import 'ring_tone.dart';
import 'theme.dart';

/// Rings for a call we are not in: a card above every page, a tone, and a
/// notification when the app is in the background. Sits in
/// [MaterialApp.builder], so pushed routes never cover it.
class IncomingCallLayer extends StatefulWidget {
  const IncomingCallLayer({
    super.key,
    required this.controller,
    required this.navigator,
    required this.child,
  });

  final AppController controller;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<IncomingCallLayer> createState() => _IncomingCallLayerState();
}

class _IncomingCallLayerState extends State<IncomingCallLayer> {
  final _tone = RingTone.incoming();
  Calls? _calls;
  IncomingCall? _ringing;

  Session? get _session => widget.controller.session;

  @override
  void initState() {
    super.initState();
    primeTones();
    widget.controller.addListener(_rewire);
    _rewire();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rewire);
    _calls?.removeListener(_sync);
    _tone.dispose();
    super.dispose();
  }

  /// Sessions come and go with login and logout; follow the current one.
  void _rewire() {
    final calls = _session?.calls;
    if (calls == _calls) return;
    _calls?.removeListener(_sync);
    _calls = calls;
    calls?.addListener(_sync);
    if (notificationsAllowed) _session?.enablePush();
    _sync();
  }

  void _sync() {
    final ringing = _calls?.ringing;
    if (ringing?.callId == _ringing?.callId) return;
    setState(() => _ringing = ringing);
    if (ringing == null) {
      _tone.stop();
      return;
    }
    _tone.start();
    final session = _session;
    if (session != null) {
      notifyRing(
        '${session.displayName(ringing.caller)} is calling',
        _groupName(session, ringing),
        tag: groupChat(ringing.groupId),
      );
    }
  }

  String _groupName(Session session, IncomingCall ringing) =>
      session.groups?.group(ringing.groupId)?.name ?? 'Group call';

  Future<void> _accept(IncomingCall ringing) async {
    final session = _session;
    final context = widget.navigator.currentContext;
    if (session == null || context == null) return;
    await openCall(context, session, ringing.groupId);
  }

  @override
  Widget build(BuildContext context) {
    final ringing = _ringing;
    final session = _session;
    return Stack(
      children: [
        widget.child,
        if (ringing != null && session != null)
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Entrance(
                    child: _RingCard(
                      session: session,
                      ringing: ringing,
                      group: _groupName(session, ringing),
                      onAccept: () => unawaited(_accept(ringing)),
                      onDecline: () => _calls?.decline(),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingCard extends StatelessWidget {
  const _RingCard({
    required this.session,
    required this.ringing,
    required this.group,
    required this.onAccept,
    required this.onDecline,
  });

  final Session session;
  final IncomingCall ringing;
  final String group;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: Panel(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            PersonAvatar(session: session, pubkey: ringing.caller, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${session.displayName(ringing.caller)} is calling',
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    group,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // No tooltip: this sits outside the navigator's Overlay.
            Semantics(
              label: 'Decline',
              button: true,
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: MangaColors.error,
                  foregroundColor: MangaColors.paper,
                ),
                icon: const Icon(Icons.call_end),
                onPressed: onDecline,
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: 'Answer',
              button: true,
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: MangaColors.ink,
                  foregroundColor: MangaColors.paper,
                ),
                icon: const TelephoneIcon(size: 22),
                onPressed: onAccept,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
