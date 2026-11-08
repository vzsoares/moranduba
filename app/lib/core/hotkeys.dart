import 'dart:convert';

import 'groups/mls_bridge.dart';

/// What a hotkey does during a call.
enum HotkeyAction {
  mute('Toggle mute'),
  deafen('Toggle deafen'),
  camera('Toggle camera'),
  hangUp('Hang up'),
  pushToTalk('Push to talk (hold)');

  const HotkeyAction(this.label);

  final String label;
}

/// A key with its modifiers. [keyId] is a Flutter PhysicalKeyboardKey
/// (USB HID) code: the key's place, unchanged by layout or by Option
/// turning M into µ on macOS.
class Hotkey {
  const Hotkey(
    this.keyId, {
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final int keyId;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  bool get hasModifier => control || alt || shift || meta;

  @override
  bool operator ==(Object other) =>
      other is Hotkey &&
      other.keyId == keyId &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, control, alt, shift, meta);

  Map<String, Object> toJson() => {
    'physical': keyId,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };

  static Hotkey? fromJson(Object? json) => switch (json) {
    {'physical': final int key} => Hotkey(
      key,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      meta: json['meta'] == true,
    ),
    _ => null,
  };
}

/// USB HID codes of the letter keys.
const _keyM = 0x00070010;
const _keyD = 0x00070007;
const _keyV = 0x00070019;
const _keyH = 0x0007000b;

/// Ctrl+Alt so browsers, which take many Ctrl+Shift combinations, leave
/// them to the app.
const defaultHotkeys = <HotkeyAction, Hotkey>{
  HotkeyAction.mute: Hotkey(_keyM, control: true, alt: true),
  HotkeyAction.deafen: Hotkey(_keyD, control: true, alt: true),
  HotkeyAction.camera: Hotkey(_keyV, control: true, alt: true),
  HotkeyAction.hangUp: Hotkey(_keyH, control: true, alt: true),
};

/// This device's hotkeys; an action missing from [bindings] has none.
class HotkeyBook {
  HotkeyBook(this._store);

  final SnapshotStore _store;
  Map<HotkeyAction, Hotkey> bindings = Map.of(defaultHotkeys);

  Future<void> load() async {
    final raw = await _store.read();
    if (raw == null) return;
    if (jsonDecode(raw) case final Map<String, Object?> saved) {
      bindings = {
        for (final action in HotkeyAction.values)
          action: ?Hotkey.fromJson(saved[action.name]),
      };
    }
  }

  /// Binds [hotkey] to [action], taking it from any other action; null
  /// unbinds.
  Future<void> put(HotkeyAction action, Hotkey? hotkey) async {
    if (hotkey == null) {
      bindings.remove(action);
    } else {
      bindings
        ..removeWhere((_, bound) => bound == hotkey)
        ..[action] = hotkey;
    }
    await _store.write(
      jsonEncode({
        for (final MapEntry(:key, :value) in bindings.entries)
          key.name: value.toJson(),
      }),
    );
  }

  HotkeyAction? actionFor(Hotkey hotkey) => bindings.entries
      .where((e) => e.value == hotkey)
      .map((e) => e.key)
      .firstOrNull;

  Future<void> wipe() => _store.delete();
}
