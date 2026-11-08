import 'dart:convert';
import 'dart:math';

import 'groups/mls_bridge.dart';

/// Text typed while no relay took it; [chat] comes from dmChat or groupChat.
class PendingMessage {
  const PendingMessage({
    required this.id,
    required this.chat,
    required this.text,
    required this.createdAt,
    this.tags = const [],
  });

  final String id;
  final String chat;
  final String text;

  /// Extra rumor tags, such as a friend acceptance's control tag.
  final List<List<String>> tags;

  /// Unix seconds, when it was typed.
  final int createdAt;

  Map<String, Object> toJson() => {
    'id': id,
    'chat': chat,
    'text': text,
    'created_at': createdAt,
    if (tags.isNotEmpty) 'tags': tags,
  };

  static PendingMessage? fromJson(Object? json) => switch (json) {
    {
      'id': final String id,
      'chat': final String chat,
      'text': final String text,
      'created_at': final int createdAt,
    } =>
      PendingMessage(
        id: id,
        chat: chat,
        text: text,
        createdAt: createdAt,
        tags: _tags(json['tags']),
      ),
    _ => null,
  };

  static List<List<String>> _tags(Object? json) => [
    if (json is List<Object?>)
      for (final tag in json)
        if (tag is List<Object?>) tag.whereType<String>().toList(),
  ];
}

/// Messages waiting for a relay, oldest first, kept across restarts.
class Outbox {
  Outbox(this._store);

  final SnapshotStore _store;
  final List<PendingMessage> _items = [];

  List<PendingMessage> get all => List.unmodifiable(_items);

  List<PendingMessage> inChat(String chat) => [
    for (final item in _items)
      if (item.chat == chat) item,
  ];

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case {'pending': final List<Object?> pending}) {
      _items.addAll(pending.map(PendingMessage.fromJson).nonNulls);
    }
  }

  Future<PendingMessage> add(
    String chat,
    String text, {
    List<List<String>> tags = const [],
  }) async {
    final random = Random.secure();
    final item = PendingMessage(
      id: [
        for (var i = 0; i < 8; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join(),
      chat: chat,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      tags: tags,
    );
    _items.add(item);
    await _save();
    return item;
  }

  Future<void> remove(String id) async {
    _items.removeWhere((item) => item.id == id);
    await _save();
  }

  Future<void> _save() => _store.write(
    jsonEncode({
      'pending': [for (final item in _items) item.toJson()],
    }),
  );

  Future<void> wipe() async {
    _items.clear();
    await _store.delete();
  }
}
