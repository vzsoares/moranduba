import 'dart:js_interop';

import 'package:sembast_web/sembast_web.dart';

import 'mls_bridge.dart';

/// Set up by web/index.html from the wasm-bindgen module in web/mls/.
@JS('morandubaMls')
external _MlsModule? get _module;

extension type _MlsModule._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;
  external String mlsCall(int handle, String method, String args);
}

MlsBridge createMlsBridge() => const _WebMlsBridge();

class _WebMlsBridge implements MlsBridge {
  const _WebMlsBridge();

  @override
  Future<void> ready() async {
    final module = _module;
    if (module == null) {
      throw StateError(
        'MLS engine not loaded. Build it with tool/build_web_mls.sh',
      );
    }
    await module.ready.toDart;
  }

  @override
  String call(int handle, String method, String args) {
    final module = _module;
    if (module == null) throw StateError('MLS engine not loaded');
    if (_crashed) throw StateError(_crashMessage);
    try {
      return module.mlsCall(handle, method, args);
    } catch (e) {
      // A Rust panic traps the wasm instance; its state is gone for good.
      _crashed = true;
      throw StateError('$_crashMessage ($e)');
    }
  }
}

bool _crashed = false;
const _crashMessage = 'The encryption engine crashed. Reload the page.';

final _snapshots = StoreRef<String, String>('snapshots');
Future<Database>? _db;

Future<SnapshotStore> openSnapshotStore(String name) async {
  final db = await (_db ??= databaseFactoryWeb.openDatabase('moranduba_mls'));
  return _IndexedDbSnapshotStore(db, name);
}

class _IndexedDbSnapshotStore implements SnapshotStore {
  _IndexedDbSnapshotStore(this._db, this._name);

  final Database _db;
  final String _name;

  @override
  Future<String?> read() => _snapshots.record(_name).get(_db);

  @override
  Future<void> write(String snapshot) =>
      _snapshots.record(_name).put(_db, snapshot);

  @override
  Future<void> delete() => _snapshots.record(_name).delete(_db);
}
