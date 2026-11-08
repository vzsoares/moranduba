import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/groups/blossom.dart';
import '../core/network.dart';
import '../core/relays.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// Relays and Blossom servers for this identity on this device. Saving
/// restarts the session through [onReconnect].
Future<void> showServerSettings(
  BuildContext context,
  Session session, {
  required Future<void> Function() onReconnect,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ServerSettings(session: session, onReconnect: onReconnect),
);

class _ServerSettings extends StatefulWidget {
  const _ServerSettings({required this.session, required this.onReconnect});

  final Session session;
  final Future<void> Function() onReconnect;

  @override
  State<_ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<_ServerSettings> {
  late final _relays = [...widget.session.relays];
  late final _blossom = [...widget.session.blossomServers];
  final _newRelay = TextEditingController();
  final _newBlossom = TextEditingController();
  String? _relayError;
  String? _blossomError;

  @override
  void dispose() {
    _newRelay.dispose();
    _newBlossom.dispose();
    super.dispose();
  }

  bool get _changed =>
      !listEquals(_relays, widget.session.relays) ||
      !listEquals(_blossom, widget.session.blossomServers);

  void _add(
    TextEditingController field,
    List<String> list,
    String? Function(String) parse,
    void Function(String?) setError,
  ) {
    final url = parse(field.text);
    setState(() {
      if (url == null) {
        setError('Not a valid address');
      } else if (list.contains(url)) {
        setError('Already in the list');
      } else {
        list.add(url);
        field.clear();
        setError(null);
      }
    });
  }

  void _defaults() => setState(() {
    _relays
      ..clear()
      ..addAll(defaultRelays);
    _blossom
      ..clear()
      ..addAll(defaultBlossomServers);
  });

  Future<void> _save() async {
    // Lists equal to the defaults are stored as none, so new defaults apply.
    await widget.session.network.save(
      relays: listEquals(_relays, defaultRelays) ? const [] : _relays,
      blossom: listEquals(_blossom, defaultBlossomServers)
          ? const []
          : _blossom,
    );
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await widget.onReconnect();
  }

  Widget _section({
    required String title,
    required String about,
    required List<String> list,
    required TextEditingController field,
    required String hint,
    required String? error,
    required VoidCallback onAdd,
  }) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: text.titleSmall),
        const SizedBox(height: 4),
        Text(about, style: text.bodySmall),
        const SizedBox(height: 8),
        for (final url in list)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(url, style: monoStyle),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              // At least one has to stay.
              onPressed: list.length == 1
                  ? null
                  : () => setState(() => list.remove(url)),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LabeledField(
                label: 'Add',
                hint: hint,
                controller: field,
                monospace: true,
                error: error,
                onSubmitted: (_) => onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: OutlinedButton(onPressed: onAdd, child: const Text('Add')),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('SERVERS'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section(
              title: 'Relays',
              about:
                  'Carry your messages, invites and call signals. Friends '
                  'find your inbox from this list. Groups keep the relays '
                  'they were made with.',
              list: _relays,
              field: _newRelay,
              hint: 'wss://relay.example.com',
              error: _relayError,
              onAdd: () =>
                  _add(_newRelay, _relays, relayUrl, (e) => _relayError = e),
            ),
            const SizedBox(height: 20),
            _section(
              title: 'File servers (Blossom)',
              about:
                  'Hold attachments, encrypted, on the first two that take '
                  'them. Servers that inspect files refuse them.',
              list: _blossom,
              field: _newBlossom,
              hint: 'https://blossom.example.com',
              error: _blossomError,
              onAdd: () => _add(
                _newBlossom,
                _blossom,
                blossomUrl,
                (e) => _blossomError = e,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: _defaults, child: const Text('Defaults')),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _changed ? _save : null,
        child: const Text('Save and reconnect'),
      ),
    ],
  );
}
