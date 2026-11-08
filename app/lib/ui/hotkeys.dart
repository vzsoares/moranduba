import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hotkeys.dart';
import '../core/session.dart';
import 'app_controller.dart';

/// [hotkey] as the keyboard event it should match, from what is held now.
Hotkey hotkeyOf(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  return Hotkey(
    event.physicalKey.usbHidUsage,
    control: keyboard.isControlPressed,
    alt: keyboard.isAltPressed,
    shift: keyboard.isShiftPressed,
    meta: keyboard.isMetaPressed,
  );
}

final _modifiers = {
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

bool isModifier(LogicalKeyboardKey key) => _modifiers.contains(key);

/// "Ctrl+Alt+M", naming the key by its place on a US keyboard.
String describeHotkey(Hotkey hotkey) => [
  if (hotkey.control) 'Ctrl',
  if (hotkey.alt) 'Alt',
  if (hotkey.shift) 'Shift',
  if (hotkey.meta) 'Cmd',
  keyName(hotkey.keyId),
].join('+');

/// Release builds drop key debug names, so common keys are named from their
/// USB HID usage (page 7).
String keyName(int code) {
  final usage = code - 0x00070000;
  return switch (usage) {
    >= 0x04 && <= 0x1d => String.fromCharCode(0x41 + usage - 0x04),
    >= 0x1e && <= 0x26 => '${usage - 0x1e + 1}',
    0x27 => '0',
    0x28 => 'Enter',
    0x29 => 'Esc',
    0x2a => 'Backspace',
    0x2b => 'Tab',
    0x2c => 'Space',
    0x35 => '`',
    >= 0x3a && <= 0x45 => 'F${usage - 0x3a + 1}',
    0x4f => 'Right',
    0x50 => 'Left',
    0x51 => 'Down',
    0x52 => 'Up',
    _ => 'Key ${code.toRadixString(16)}',
  };
}

/// Runs the session's hotkeys during a call, from anywhere in the app.
/// Sits in [MaterialApp.builder].
class HotkeyLayer extends StatefulWidget {
  const HotkeyLayer({super.key, required this.controller, required this.child});

  final AppController controller;
  final Widget child;

  @override
  State<HotkeyLayer> createState() => _HotkeyLayerState();
}

class _HotkeyLayerState extends State<HotkeyLayer> {
  /// The push-to-talk key while held, so its release ends the talk.
  int? _talking;

  Session? get _session => widget.controller.session;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Plain keys are left alone while someone types.
  bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  bool _onKey(KeyEvent event) {
    final session = _session;
    final call = session?.calls?.active;
    if (session == null || call == null || call.closed) return false;
    if (event is KeyUpEvent && event.physicalKey.usbHidUsage == _talking) {
      _talking = null;
      unawaited(call.setMic(false));
      return true;
    }
    if (event is! KeyDownEvent || isModifier(event.logicalKey)) return false;
    final hotkey = hotkeyOf(event);
    if (!hotkey.hasModifier && _typing) return false;
    switch (session.hotkeys.actionFor(hotkey)) {
      case HotkeyAction.mute:
        unawaited(call.setMic(!call.micOn));
      case HotkeyAction.deafen:
        unawaited(call.setDeafened(!call.deafened));
      case HotkeyAction.camera:
        unawaited(call.setCamera(!call.cameraOn).catchError((Object _) {}));
      case HotkeyAction.hangUp:
        unawaited(session.calls?.leave());
      case HotkeyAction.pushToTalk:
        _talking = event.physicalKey.usbHidUsage;
        unawaited(call.setMic(true));
      case null:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Lists the call hotkeys; click one, then press the new combination.
Future<void> showHotkeySettings(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _HotkeySettings(session: session),
    );

class _HotkeySettings extends StatefulWidget {
  const _HotkeySettings({required this.session});

  final Session session;

  @override
  State<_HotkeySettings> createState() => _HotkeySettingsState();
}

class _HotkeySettingsState extends State<_HotkeySettings> {
  HotkeyAction? _recording;
  final _focus = FocusNode();

  HotkeyBook get book => widget.session.hotkeys;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _record(HotkeyAction action) {
    setState(() => _recording = action);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final action = _recording;
    if (action == null || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isModifier(event.logicalKey)) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = null);
      return KeyEventResult.handled;
    }
    final hotkey = hotkeyOf(event);
    setState(() => _recording = null);
    unawaited(
      book.put(action, hotkey).then((_) {
        if (mounted) setState(() {});
      }),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onKeyEvent: _onKey,
    child: AlertDialog(
      title: const Text('HOTKEYS'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'They work anywhere in the app during a call. Click one, then '
              'press the new keys; Esc cancels.',
            ),
            const SizedBox(height: 12),
            for (final action in HotkeyAction.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(action.label),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: () => _record(action),
                      child: Text(switch ((_recording, book.bindings[action])) {
                        (final r, _) when r == action => 'Press keys…',
                        (_, final hotkey?) => describeHotkey(hotkey),
                        _ => 'Not set',
                      }),
                    ),
                    IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: book.bindings[action] == null
                          ? null
                          : () => unawaited(
                              book.put(action, null).then((_) {
                                if (mounted) setState(() {});
                              }),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
