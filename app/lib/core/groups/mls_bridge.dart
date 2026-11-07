/// Transport to the Rust MLS engine: FFI on desktop, wasm in the browser.
abstract interface class MlsBridge {
  /// Completes once the engine can take calls.
  Future<void> ready();

  /// One synchronous engine call. Replies `{"ok": …}` or `{"err": "…"}`.
  String call(int handle, String method, String args);
}

/// Where an identity's encrypted engine snapshot is kept.
abstract interface class SnapshotStore {
  Future<String?> read();
  Future<void> write(String snapshot);
  Future<void> delete();
}

class MemorySnapshotStore implements SnapshotStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String snapshot) async => value = snapshot;

  @override
  Future<void> delete() async => value = null;
}
