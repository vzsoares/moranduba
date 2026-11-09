import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/groups/blossom.dart';
import '../core/network.dart';
import '../core/relays.dart';
import '../core/session.dart';
import 'manga.dart';
import 'theme.dart';

/// Relays, Blossom and TURN servers for this identity on this device.
/// Saving new relays or Blossom servers restarts the session through
/// [onReconnect]; TURN servers apply from the next call.
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
  late final _turn = [...widget.session.network.turn];
  final _newRelay = TextEditingController();
  final _newBlossom = TextEditingController();
  final _newTurn = TextEditingController();
  final _turnUser = TextEditingController();
  final _turnPassword = TextEditingController();
  String? _relayError;
  String? _blossomError;
  String? _turnError;

  @override
  void dispose() {
    _newRelay.dispose();
    _newBlossom.dispose();
    _newTurn.dispose();
    _turnUser.dispose();
    _turnPassword.dispose();
    super.dispose();
  }

  bool get _reconnects =>
      !listEquals(_relays, widget.session.relays) ||
      !listEquals(_blossom, widget.session.blossomServers);

  bool get _changed =>
      _reconnects || !listEquals(_turn, widget.session.network.turn);

  void _addTurn() {
    final url = turnUrl(_newTurn.text);
    final server = url == null
        ? null
        : TurnServer(
            url: url,
            username: _turnUser.text.trim(),
            credential: _turnPassword.text,
          );
    setState(() {
      if (server == null) {
        _turnError = 'Not a TURN address';
      } else if (_turn.contains(server)) {
        _turnError = 'Already in the list';
      } else {
        _turn.add(server);
        _newTurn.clear();
        _turnUser.clear();
        _turnPassword.clear();
        _turnError = null;
      }
    });
  }

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
    final reconnect = _reconnects;
    // Lists equal to the defaults are stored as none, so new defaults apply.
    await widget.session.network.save(
      relays: listEquals(_relays, defaultRelays) ? const [] : _relays,
      blossom: listEquals(_blossom, defaultBlossomServers)
          ? const []
          : _blossom,
      turn: _turn,
    );
    if (!mounted) return;
    if (!reconnect) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    await widget.onReconnect();
  }

  Widget _turnSection() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Call relays (TURN)', style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          'For calls without a call server, when two people cannot connect '
          'directly and nobody else in the call can pass their media on. '
          'The TURN server sees your IP address, never the media. Optional.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final server in _turn)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(server.url, style: monoStyle),
            subtitle: server.username.isEmpty ? null : Text(server.username),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _turn.remove(server)),
            ),
          ),
        LabeledField(
          label: 'Add',
          hint: 'turn:turn.example.com:3478',
          controller: _newTurn,
          monospace: true,
          error: _turnError,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LabeledField(label: 'Username', controller: _turnUser),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LabeledField(
                label: 'Password',
                controller: _turnPassword,
                obscure: true,
                onSubmitted: (_) => _addTurn(),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: OutlinedButton(
                onPressed: _addTurn,
                child: const Text('Add'),
              ),
            ),
          ],
        ),
      ],
    );
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
            const SizedBox(height: 20),
            _turnSection(),
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
        child: Text(_reconnects ? 'Save and reconnect' : 'Save'),
      ),
    ],
  );
}
