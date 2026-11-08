import 'package:flutter/foundation.dart';

import '../core/groups/rust_group_engine.dart';
import '../core/identity.dart';
import '../core/groups/mls_platform.dart';
import '../core/identity_store.dart';
import '../core/network.dart';
import '../core/session.dart';

enum AppStage { loading, onboarding, ready, failed }

class AppController extends ChangeNotifier {
  AppController(this._secrets) : _store = IdentityStore(_secrets);

  final SecretStore _secrets;
  final IdentityStore _store;

  AppStage stage = AppStage.loading;
  Session? session;
  Object? error;

  Future<void> restore() async {
    final identity = await _store.load();
    if (identity == null) {
      _set(AppStage.onboarding);
      return;
    }
    await _open(identity);
  }

  Future<void> create() => _adopt(Identity.generate());

  Future<void> import(String nsecOrHex) => _adopt(Identity.parse(nsecOrHex));

  Future<void> logout() async {
    await session?.wipe();
    session = null;
    await _store.clear();
    _set(AppStage.onboarding);
  }

  /// Starts the session again, picking up changed relays and servers.
  Future<void> reconnect() async {
    final current = session;
    if (current == null) return;
    await current.close();
    session = null;
    await _open(current.identity);
  }

  /// Whether the last start used relays or servers chosen in settings.
  bool customServers = false;

  /// Forgets chosen relays and servers, then starts again.
  Future<void> useDefaultServers() async {
    final identity = await _store.load();
    if (identity == null) return;
    await NetworkBook(await openSnapshotStore('${identity.publicKey}-network'))
        .wipe();
    await _open(identity);
  }

  Future<void> _adopt(Identity identity) async {
    await _store.save(identity);
    await _open(identity);
  }

  Future<void> _open(Identity identity) async {
    _set(AppStage.loading);
    final network = NetworkBook(
      await openSnapshotStore('${identity.publicKey}-network'),
    );
    await network.load();
    customServers = network.relays != null || network.blossom != null;
    try {
      session = await Session.start(
        identity,
        openGroupEngine: () => openGroupEngine(identity, _secrets),
      );
      _set(AppStage.ready);
    } catch (e) {
      error = e;
      _set(AppStage.failed);
    }
  }

  void _set(AppStage next) {
    stage = next;
    notifyListeners();
  }
}
