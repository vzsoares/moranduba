import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'mls_bridge.dart';
import 'mls_native.dart';

MlsBridge createMlsBridge() => const NativeMlsBridge();

Future<SnapshotStore> openSnapshotStore(String name) async {
  final support = await getApplicationSupportDirectory();
  return FileSnapshotStore(File('${support.path}/mls/$name.snapshot'));
}

class FileSnapshotStore implements SnapshotStore {
  FileSnapshotStore(this.file);

  final File file;

  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;

  /// Writes beside the target and renames, so a crash keeps the old copy.
  @override
  Future<void> write(String snapshot) async {
    await file.parent.create(recursive: true);
    final next = File('${file.path}.next');
    await next.writeAsString(snapshot, flush: true);
    await next.rename(file.path);
  }

  @override
  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}
