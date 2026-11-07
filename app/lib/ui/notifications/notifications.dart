import 'dart:async';

import '../../core/push/push.dart';
import '../../core/session.dart';
import 'notifications_native.dart'
    if (dart.library.js_interop) 'notifications_web.dart'
    as platform;

/// Whether this platform can show notifications.
bool get notificationsSupported => platform.supported;

bool get notificationsAllowed => platform.allowed;

/// Whether the app's switch can turn notifications off again.
bool get notificationsRevocable => platform.revocable;

/// Reads the saved switch; call before the first frame.
Future<void> loadNotifications() => platform.load();

/// Asks the user; returns whether notifications are on.
Future<bool> askForNotifications() => platform.ask();

Future<void> turnOffNotifications() => platform.turnOff();

/// Shows [session]'s notices while the app is in the background.
StreamSubscription<Notice> showNotices(Session session) =>
    session.notices.listen((notice) {
      if (platform.allowed && platform.inBackground) {
        platform.show(notice.title, notice.body, tag: notice.chat);
      }
    });

/// Tells about a ringing call while the app is in the background; the
/// chat's [tag] lets it replace that chat's message notification.
void notifyRing(String title, String body, {required String tag}) {
  if (platform.allowed && platform.inBackground) {
    platform.show(title, body, tag: tag);
  }
}

/// Shows a ring pushed while the app is closed or in the background; the
/// open app rings by itself.
void showPushRing(PushRing ring) {
  if (ring.stop) {
    platform.cancel(_pushTag);
  } else if (platform.allowed && platform.inBackground) {
    platform.show('Incoming call', 'Open Moranduba to answer.', tag: _pushTag);
  }
}

const _pushTag = 'ring';
