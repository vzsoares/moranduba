import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moranduba/core/groups/mls_bridge.dart';
import 'package:moranduba/core/hotkeys.dart';
import 'package:moranduba/ui/hotkeys.dart';

void main() {
  test('defaults name the M and H keys by place', () {
    expect(
      defaultHotkeys[HotkeyAction.mute]?.keyId,
      PhysicalKeyboardKey.keyM.usbHidUsage,
    );
    expect(
      defaultHotkeys[HotkeyAction.hangUp]?.keyId,
      PhysicalKeyboardKey.keyH.usbHidUsage,
    );
  });

  test('a combination moves to its new action and survives a reload', () async {
    final store = MemorySnapshotStore();
    final book = HotkeyBook(store);
    final ctrlAltM = defaultHotkeys[HotkeyAction.mute]!;
    await book.put(HotkeyAction.pushToTalk, ctrlAltM);
    expect(book.actionFor(ctrlAltM), HotkeyAction.pushToTalk);
    expect(book.bindings[HotkeyAction.mute], isNull);

    await book.put(HotkeyAction.deafen, null);
    final reloaded = HotkeyBook(store);
    await reloaded.load();
    expect(reloaded.bindings[HotkeyAction.pushToTalk], ctrlAltM);
    expect(reloaded.bindings.containsKey(HotkeyAction.deafen), isFalse);
    expect(reloaded.bindings[HotkeyAction.camera], isNotNull);
  });

  test('keys are named from their USB code', () {
    expect(keyName(PhysicalKeyboardKey.keyM.usbHidUsage), 'M');
    expect(keyName(PhysicalKeyboardKey.digit0.usbHidUsage), '0');
    expect(keyName(PhysicalKeyboardKey.digit1.usbHidUsage), '1');
    expect(keyName(PhysicalKeyboardKey.f12.usbHidUsage), 'F12');
    expect(keyName(PhysicalKeyboardKey.backquote.usbHidUsage), '`');
    expect(describeHotkey(defaultHotkeys[HotkeyAction.deafen]!), 'Ctrl+Alt+D');
  });
}
