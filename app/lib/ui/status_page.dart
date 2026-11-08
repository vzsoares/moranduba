import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/calls/host_peer.dart';
import '../core/session.dart';
import '../core/status.dart';
import 'theme.dart';

/// Checks every relay, file server and call server this device uses, plus
/// the encryption engine and call hosting.
Future<void> showConnectionStatus(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ConnectionStatus(session: session),
    );

class _ConnectionStatus extends StatefulWidget {
  const _ConnectionStatus({required this.session});

  final Session session;

  @override
  State<_ConnectionStatus> createState() => _ConnectionStatusState();
}

class _ConnectionStatusState extends State<_ConnectionStatus> {
  final Map<String, StatusCheck> _results = {};
  int _round = 0;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _checkAll();
  }

  void _checkAll() {
    final round = ++_round;
    setState(_results.clear);
    void run(String key, Future<StatusCheck> check) => check.then((result) {
      if (mounted && round == _round) setState(() => _results[key] = result);
    });
    for (final url in _session.relays) {
      run('relay $url', _session.status.relay(url));
    }
    for (final url in _session.blossomServers) {
      run('file $url', _session.status.fileServer(url));
    }
    for (final pubkey in _session.callServers.keys) {
      run(
        'sfu $pubkey',
        _session.status.callServer(() => _session.pingServer(pubkey)),
      );
    }
  }

  StatusCheck get _engine {
    if (_session.groupsError case final error?) {
      return StatusCheck(
        Health.down,
        'Groups are off: ${describeError(error)}',
      );
    }
    final groups = _session.groups;
    if (groups == null) return const StatusCheck(Health.down, 'Not started');
    if (groups.keyPackageError case final error?) {
      return StatusCheck(
        Health.slow,
        'Groups work, but nobody can invite you until a relay takes your '
        'key package: ${describeError(error)}',
      );
    }
    return const StatusCheck(Health.ok, 'Running');
  }

  StatusCheck? get _hosting {
    final desktop =
        !kIsWeb &&
        const {
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
    if (!desktop) return null;
    if (_session.hosting != null) {
      return const StatusCheck(Health.ok, 'Hosting calls now');
    }
    return canHostCalls
        ? const StatusCheck(Health.ok, 'Ready to host calls')
        : const StatusCheck(
            Health.down,
            'The call server is missing from this install',
          );
  }

  @override
  Widget build(BuildContext context) {
    final servers = _session.callServers;
    final hosting = _hosting;
    return AlertDialog(
      title: const Text('CONNECTION STATUS'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Heading('Encryption engine'),
              _Row(label: 'Groups', check: _engine),
              const _Heading('Relays'),
              for (final url in _session.relays)
                _Row(label: url, mono: true, check: _results['relay $url']),
              const _Heading('File servers'),
              for (final url in _session.blossomServers)
                _Row(label: url, mono: true, check: _results['file $url']),
              const _Heading('Call servers'),
              if (servers.isEmpty)
                const _Row(
                  label: 'None',
                  check: StatusCheck(
                    Health.ok,
                    'Calls connect directly between members',
                  ),
                ),
              for (final MapEntry(key: pubkey, value: users) in servers.entries)
                _Row(
                  label: '${pubkey.substring(0, 12)}… · ${users.join(', ')}',
                  mono: true,
                  check: _results['sfu $pubkey'],
                ),
              if (hosting != null) ...[
                const _Heading('This computer'),
                _Row(label: 'Call hosting', check: hosting),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _checkAll, child: const Text('Check again')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.check, this.mono = false});

  final String label;
  final bool mono;

  /// Null while the check runs.
  final StatusCheck? check;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final check = this.check;
    final latency = check?.latency;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 20,
            child: switch (check?.health) {
              null => const Padding(
                padding: EdgeInsets.all(3),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Health.ok => const Icon(Icons.check_circle_outline, size: 20),
              Health.slow => const Icon(Icons.warning_amber_rounded, size: 20),
              Health.down => const Icon(
                Icons.cancel_outlined,
                size: 20,
                color: MangaColors.error,
              ),
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: mono ? monoStyle : text.bodyMedium),
                Text(
                  check == null ? 'Checking…' : check.detail,
                  style: text.bodySmall?.copyWith(
                    color: check?.health == Health.down
                        ? MangaColors.error
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (latency != null)
            Text('${latency.inMilliseconds} ms', style: monoStyle),
        ],
      ),
    );
  }
}
