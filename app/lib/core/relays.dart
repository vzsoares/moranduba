const _override = String.fromEnvironment('MORANDUBA_RELAYS');

/// Relays used for discovery, DM inboxes and the friend list.
/// Override with `--dart-define=MORANDUBA_RELAYS=ws://localhost:7777,…`.
List<String> get defaultRelays => _override.isEmpty
    ? const ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net']
    : _override.split(',').map((url) => url.trim()).toList();
