import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'mls_bridge.dart';

// Symbols from rust/src/lib.rs, bundled by hook/build.dart.
@Native<Pointer<Utf8> Function(Uint32, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'moranduba_mls_call',
)
external Pointer<Utf8> _call(
  int handle,
  Pointer<Utf8> method,
  Pointer<Utf8> args,
);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'moranduba_mls_free')
external void _free(Pointer<Utf8> reply);

class NativeMlsBridge implements MlsBridge {
  const NativeMlsBridge();

  @override
  Future<void> ready() async {}

  @override
  String call(int handle, String method, String args) {
    final m = method.toNativeUtf8();
    final a = args.toNativeUtf8();
    try {
      final reply = _call(handle, m, a);
      try {
        return reply.toDartString();
      } finally {
        _free(reply);
      }
    } finally {
      malloc
        ..free(m)
        ..free(a);
    }
  }
}
