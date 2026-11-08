import 'package:flutter/material.dart';
import 'package:ndk/shared/nips/nip19/nip19.dart';
import 'package:path_provider/path_provider.dart';

import '../core/calls/host_peer.dart';
import '../core/identity.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// Picks the group's call server (`server` mode), or direct calls (mesh),
/// and offers this desktop as a host peer.
class ServerDialog extends StatefulWidget {
  const ServerDialog({super.key, required this.session, required this.groupId});

  final Session session;
  final String groupId;

  @override
  State<ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<ServerDialog> {
  late final _npub = TextEditingController(
    text: switch (widget.session.serverOf(widget.groupId)) {
      final pubkey? => Nip19.encodePubKey(pubkey),
      null => '',
    },
  );
  final _code = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _error;

  Session get session => widget.session;

  @override
  void dispose() {
    _npub.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final status = await action();
      if (mounted) setState(() => _status = status);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _test() async {
    final pong = await session.pingServer(parsePublicKey(_npub.text));
    return switch ((pong['allowed'], pong['owner'])) {
      (_, true) => 'Online. You own it.',
      (true, _) => 'Online. It knows you.',
      _ => 'Online, but it does not know you yet. Its owner adds you.',
    };
  }

  Future<String> _save() async {
    // No npub means no server; hosting on this computer applies on its own.
    if (_npub.text.trim().isEmpty) {
      if (session.serverOf(widget.groupId) != null) {
        await session.setServer(widget.groupId, null);
      }
      if (mounted) Navigator.of(context).pop();
      return 'Saved';
    }
    final sfu = parsePublicKey(_npub.text);
    final code = _code.text.trim();
    if (code.isNotEmpty) await session.claimServer(sfu, code);
    await session.setServer(widget.groupId, sfu);
    if (mounted) Navigator.of(context).pop();
    return 'Saved';
  }

  Future<String> _host() async {
    final support = await getApplicationSupportDirectory();
    await session.hostCalls(widget.groupId, dataDir: '${support.path}/sfu');
    return 'Hosting calls for this group while the app is open.';
  }

  Future<String> _unhost() async {
    await session.unhostCalls(widget.groupId);
    return 'No longer hosting for this group.';
  }

  Future<String> _direct() async {
    await session.setServer(widget.groupId, null);
    if (mounted) Navigator.of(context).pop();
    return 'Saved';
  }

  @override
  Widget build(BuildContext context) {
    final current = session.serverOf(widget.groupId);
    final hosts = session.hostsOf(widget.groupId).length;
    final hostingHere = session.hostsCallsFor(widget.groupId);
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('CALL SERVER'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current == null
                    ? 'Calls in this group go directly between members. A '
                          'Moranduba server carries bigger calls; it only '
                          'ever sees encrypted frames.'
                    : 'Calls in this group go through this server when it '
                          'is online, and directly between members when not.',
              ),
              if (hosts > 0) ...[
                const SizedBox(height: 8),
                Text(
                  [
                    hosts == 1
                        ? "1 member's computer hosts calls"
                        : "$hosts members' computers host calls",
                    if (current != null) ' when the server is offline',
                    '.',
                  ].join(),
                  style: text.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              Text('Server', style: text.titleSmall),
              const SizedBox(height: 8),
              LabeledField(
                label: 'Server npub (empty for none)',
                hint: 'npub1… printed by the server',
                controller: _npub,
                monospace: true,
              ),
              const SizedBox(height: 12),
              LabeledField(
                label: 'Claim code (only when setting up a new server)',
                hint: 'Leave empty if someone else runs it',
                controller: _code,
                monospace: true,
              ),
              if (canHostCalls) ...[
                const SizedBox(height: 20),
                Text('This computer', style: text.titleSmall),
                const SizedBox(height: 4),
                Text(
                  hostingHere
                      ? 'Hosting calls for this group while the app is open.'
                      : 'Members can call through this computer while the '
                            'app is open. Starts right away, no need to save.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.computer, size: 18),
                  label: Text(
                    hostingHere
                        ? 'Stop hosting calls on this computer'
                        : 'Host calls on this computer',
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(hostingHere ? _unhost : _host),
                ),
              ],
              if (_status case final status?) ...[
                const SizedBox(height: 12),
                Text(status, style: text.bodyMedium),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                SelectableText(
                  error,
                  style: const TextStyle(color: MangaColors.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (current != null)
            TextButton(
              onPressed: _busy ? null : () => _run(_direct),
              child: const Text('Call directly'),
            ),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(_test),
            child: const Text('Test'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _run(_save),
            child: Text(_busy ? 'Working…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
