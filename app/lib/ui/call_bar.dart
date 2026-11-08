import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/calls/calls.dart';
import '../core/session.dart';
import 'app_controller.dart';
import 'call_page.dart';
import 'theme.dart';

/// While a call runs and its page is closed: a strip above every page with
/// the call's name and length, mute and hang up; tap it to go back. Sits in
/// [MaterialApp.builder], outside the navigator.
class CallBarLayer extends StatefulWidget {
  const CallBarLayer({
    super.key,
    required this.controller,
    required this.navigator,
    required this.child,
  });

  final AppController controller;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<CallBarLayer> createState() => _CallBarLayerState();
}

class _CallBarLayerState extends State<CallBarLayer> {
  Calls? _calls;
  Timer? _clock;

  Session? get _session => widget.controller.session;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rewire);
    callPageOpen.addListener(_changed);
    _rewire();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rewire);
    callPageOpen.removeListener(_changed);
    _calls?.removeListener(_changed);
    _clock?.cancel();
    super.dispose();
  }

  void _rewire() {
    final calls = _session?.calls;
    if (calls == _calls) return;
    _calls?.removeListener(_changed);
    _calls = calls;
    calls?.addListener(_changed);
    _changed();
  }

  bool get _showing {
    final call = _calls?.active;
    return call != null && !call.closed && callPageOpen.value == 0;
  }

  void _changed() {
    if (!mounted) return;
    // A call page opening or closing can report mid-frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    if (_showing) {
      _clock ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    } else {
      _clock?.cancel();
      _clock = null;
    }
    setState(() {});
  }

  Future<void> _open(String groupId) async {
    final session = _session;
    final context = widget.navigator.currentContext;
    if (session == null || context == null) return;
    await openCall(context, session, groupId);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final calls = _calls;
    final call = calls?.active;
    if (!_showing || session == null || calls == null || call == null) {
      return widget.child;
    }
    final name = session.groups?.group(call.groupId)?.name ?? 'Call';
    final seconds =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - call.joinedAt;
    final length =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    const ink = TextStyle(
      color: MangaColors.paper,
      fontWeight: FontWeight.w700,
    );
    return Column(
      children: [
        Material(
          color: MangaColors.ink,
          child: SafeArea(
            bottom: false,
            child: InkWell(
              onTap: () => unawaited(_open(call.groupId)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.graphic_eq, color: MangaColors.paper),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'In call · $name · $length · tap to return',
                        style: ink,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // No tooltips: this sits outside the navigator's Overlay.
                    Semantics(
                      label: call.micOn ? 'Mute' : 'Unmute',
                      button: true,
                      child: IconButton(
                        color: MangaColors.paper,
                        icon: Icon(call.micOn ? Icons.mic : Icons.mic_off),
                        onPressed: () => call.setMic(!call.micOn),
                      ),
                    ),
                    Semantics(
                      label: call.deafened ? 'Undeafen' : 'Deafen',
                      button: true,
                      child: IconButton(
                        color: MangaColors.paper,
                        icon: Icon(
                          call.deafened ? Icons.headset_off : Icons.headset,
                        ),
                        onPressed: () => call.setDeafened(!call.deafened),
                      ),
                    ),
                    Semantics(
                      label: 'Hang up',
                      button: true,
                      child: IconButton(
                        color: MangaColors.error,
                        icon: const Icon(Icons.call_end),
                        onPressed: () => unawaited(calls.leave()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
