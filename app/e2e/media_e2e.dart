// Browser check of attachments: Alice sends a picture, audio, a PDF and an
// unknown file; Bob decrypts each and opens the viewer. Needs the dev Blossom
// server (:8800). Logs "E2E media shot <name>" for the runner's screenshots.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:moranduba/core/groups/blossom.dart';
import 'package:moranduba/core/groups/group_engine.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/groups/mls_platform.dart';
import 'package:moranduba/core/groups/rust_group_engine.dart';
import 'package:moranduba/core/identity.dart';
import 'package:moranduba/core/session.dart';
import 'package:moranduba/ui/groups_page.dart';
import 'package:moranduba/ui/media_viewer.dart';
import 'package:moranduba/ui/theme.dart';

const _relays = ['ws://localhost:7777'];
final _blossom = BlossomClient(servers: ['http://localhost:8800']);
final _navigator = GlobalKey<NavigatorState>();

void _log(String line) => debugPrint('E2E media $line');

Future<void> _until(String what, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<Session> _start(Identity id) => Session.start(
  id,
  relays: _relays,
  blossom: _blossom,
  openGroupEngine: () => RustGroupEngine.open(
    bridge: createMlsBridge(),
    secretKey: id.privateKey,
    storageKey: '33' * 32,
    store: MemorySnapshotStore(),
  ),
);

/// One second of a 440 Hz tone as 16-bit mono WAV.
Uint8List _wav() {
  const rate = 8000;
  final samples = ByteData(rate * 2);
  for (var i = 0; i < rate; i++) {
    samples.setInt16(
      i * 2,
      (sin(2 * pi * 440 * i / rate) * 12000).round(),
      Endian.little,
    );
  }
  final header = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + rate * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, rate * 2, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...samples.buffer.asUint8List(),
  ]);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _scenario();
    _log('PASS');
  } catch (e, stack) {
    _log('FAIL $e\n$stack');
  }
}

Future<void> _scenario() async {
  final aliceId = Identity.generate();
  final bobId = Identity.generate();
  final alice = await _start(aliceId);
  final bob = await _start(bobId);
  final group = await alice.groups!.create('media', [bobId.publicKey]);
  final bobGroups = bob.groups!;
  await _until('invite', () => bobGroups.invites.isNotEmpty);
  await bobGroups.accept(bobGroups.invites.single.id);

  final files = <String, Uint8List>{
    'checker.png': base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAA6klEQVR4nOXOsQ0AMAzDsPz/dHuBZzOIZg6aF5rQNc8NaZ4b0jw3pHluSPPckOa5Ic1zQ5qPaaOa54Y0zw1pnhvSPDekeW5I89yQ5rmhml8zWvLckOa5Ic1zQ5rnhjTPDWmeG9I8N6T5mDaqeW5I89yQ5rkhzXNDmueGNM8NaZ4bqvk1oyXPDWmeG9I8N6R5bkjz3JDmuSHNc0Oaj2mjmueGNM8NaZ4b0jw3pHluSPPckOa5oZpfM1ry3JDmuSHNc0Oa54Y0zw1pnhvSPDek+Zg2qnluSPPckOa5Ic1zQ5rnhjTPDWmeG2r5D7P53g7RnEOoAAAAAElFTkSuQmCC',
    ),
    'tone.wav': _wav(),
    'brief.pdf': Uint8List.fromList(utf8.encode('%PDF-1.4\n%%EOF\n')),
    'notes.bin': Uint8List.fromList(List.generate(64, (i) => i)),
  };
  for (final MapEntry(key: name, value: bytes) in files.entries) {
    await alice.groups!.sendFile(
      group.id,
      bytes,
      mime: _mime(name),
      filename: name,
    );
  }
  await _until(
    'all attachments',
    () =>
        bobGroups
            .messagesIn(group.id)
            .where((m) => m.media.isNotEmpty)
            .length ==
        files.length,
  );
  final refs = <String, MediaRef>{
    for (final m in bobGroups.messagesIn(group.id))
      for (final media in m.media) media.filename: media,
  };
  for (final MapEntry(key: name, value: bytes) in files.entries) {
    final got = await bobGroups.media(group.id, refs[name]!);
    // Pictures are re-encoded without metadata; everything else is exact.
    if (!name.endsWith('.png') && !_same(got, bytes)) {
      throw StateError('$name came back different');
    }
  }
  _log('decrypted all');

  runApp(
    MaterialApp(
      navigatorKey: _navigator,
      theme: mangaTheme(),
      debugShowCheckedModeBanner: false,
      home: GroupChatPage(session: bob, groupId: group.id),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  _log('shot chat');
  await Future<void>.delayed(const Duration(seconds: 3));

  for (final name in ['checker.png', 'tone.wav', 'brief.pdf']) {
    unawaited(
      showMediaViewer(
        _navigator.currentContext!,
        groups: bobGroups,
        groupId: group.id,
        media: refs[name]!,
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    _log('shot viewer-${name.split('.').last}');
    await Future<void>.delayed(const Duration(seconds: 3));
    _navigator.currentState!.pop();
  }
  await alice.close();
  await bob.close();
}

String _mime(String name) => switch (name.split('.').last) {
  'png' => 'image/png',
  'wav' => 'audio/wav',
  'pdf' => 'application/pdf',
  _ => 'application/octet-stream',
};

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
