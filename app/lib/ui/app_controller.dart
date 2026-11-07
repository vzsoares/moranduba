import 'package:flutter/foundation.dart';

import '../core/groups/rust_group_engine.dart';
import '../core/identity.dart';
import '../core/identity_store.dart';
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

  Future<void> _adopt(Identity identity) async {
    await _store.save(identity);
    await _open(identity);
  }

  Future<void> _open(Identity identity) async {
    _set(AppStage.loading);
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
