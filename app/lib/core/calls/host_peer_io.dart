import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'host_identity.dart';

export 'host_identity.dart';

/// The SFU binary: `MORANDUBA_SFU_BIN`, else bundled next to the app.
String? get _binary {
  final override = Platform.environment['MORANDUBA_SFU_BIN'];
  if (override != null && override.isNotEmpty) return override;
  final dir = File(Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows ? 'moranduba-sfu.exe' : 'moranduba-sfu';
  for (final candidate in [
    '$dir/$name',
    // macOS: Contents/MacOS next to Contents/Resources.
    '$dir/../Resources/$name',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

bool get canHostCalls =>
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
    _binary != null;

/// Starts the SFU as a child process and waits for its identity line.
Future<HostedSfu> startHostedSfu({
  required String dataDir,
  required List<String> relays,
}) async {
  final binary = _binary;
  if (binary == null) throw StateError('The call server is not bundled');
  final process = await Process.start(
    binary,
    const [],
    environment: {
      'DATA_DIR': dataDir,
      'RELAYS': relays.join(','),
      'SFU_EXIT_ON_STDIN_EOF': '1',
    },
  );
  final identity = Completer<HostIdentity>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      final parsed = HostIdentity.parse(line);
      if (parsed != null && !identity.isCompleted) {
        identity.complete(parsed);
      }
    },
  );
  process.stderr
      .transform(utf8.decoder)
      .listen((chunk) => debugPrint('sfu: $chunk'));
  unawaited(
    process.exitCode.then((code) {
      if (!identity.isCompleted) {
        identity.completeError(StateError('Call server exited with $code'));
      }
    }),
  );
  try {
    return _ProcessSfu(
      process,
      await identity.future.timeout(const Duration(seconds: 15)),
    );
  } catch (_) {
    process.kill();
    rethrow;
  }
}

class _ProcessSfu implements HostedSfu {
  _ProcessSfu(this._process, this.identity);

  final Process _process;

  @override
  final HostIdentity identity;

  @override
  Future<void> stop() async {
    // Closing stdin lets it exit on its own; the signal is the fallback.
    await _process.stdin.close();
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
