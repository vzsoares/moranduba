import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

final _plugin = FlutterLocalNotificationsPlugin();
bool _on = false;
bool _ready = false;

const _android = AndroidNotificationDetails(
  'messages',
  'Messages',
  channelDescription: 'New messages while Moranduba is in the background',
  importance: Importance.high,
  priority: Priority.high,
);

bool get supported =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isLinux ||
    Platform.isWindows;

bool get allowed => _on;

/// The OS keeps the permission; the app keeps its own switch on top.
bool get revocable => true;

bool get inBackground =>
    WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

Future<File> _flag() async =>
    File('${(await getApplicationSupportDirectory()).path}/notify');

Future<void> load() async {
  if (!supported) return;
  try {
    _on = await (await _flag()).exists();
    if (_on) await _init();
  } catch (e) {
    debugPrint('notifications: $e');
    _on = false;
  }
}

Future<void> _init() async {
  if (_ready) return;
  _ready =
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'Moranduba',
            appUserModelId: 'io.github.vzsoares.moranduba',
            guid: '36ac646e-c066-4f21-bc6e-061f9e7a08d9',
          ),
        ),
      ) ??
      false;
}

Future<bool> _permission() async {
  if (Platform.isAndroid) {
    return await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        false;
  }
  if (Platform.isIOS) {
    return await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true) ??
        false;
  }
  if (Platform.isMacOS) {
    return await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true) ??
        false;
  }
  return true;
}

Future<bool> ask() async {
  try {
    await _init();
    _on = _ready && await _permission();
    final flag = await _flag();
    if (_on) await flag.writeAsString('1');
  } catch (e) {
    debugPrint('notifications: $e');
    _on = false;
  }
  return _on;
}

Future<void> turnOff() async {
  _on = false;
  final flag = await _flag();
  if (await flag.exists()) await flag.delete();
}

/// One notification per chat ([tag]); a newer message replaces it.
void show(String title, String body, {required String tag}) {
  if (!_ready) return;
  _plugin
      .show(
        id: tag.hashCode & 0x7fffffff,
        title: title,
        body: body.length > 140 ? '${body.substring(0, 140)}…' : body,
        notificationDetails: NotificationDetails(
          android: _android,
          iOS: DarwinNotificationDetails(threadIdentifier: tag),
          macOS: DarwinNotificationDetails(threadIdentifier: tag),
        ),
      )
      .ignore();
}

void cancel(String tag) {
  if (!_ready) return;
  _plugin.cancel(id: tag.hashCode & 0x7fffffff).ignore();
}
