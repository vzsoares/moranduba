import 'dart:async';

import '../../core/session.dart';
import 'notifications_stub.dart'
    if (dart.library.js_interop) 'notifications_web.dart'
    as platform;

/// Whether this platform can show notifications yet.
bool get notificationsSupported => platform.supported;

bool get notificationsAllowed => platform.allowed;

/// Asks the user; returns whether notifications are on.
Future<bool> askForNotifications() => platform.ask();

/// Shows [session]'s notices while the app is in the background.
StreamSubscription<Notice> showNotices(Session session) =>
    session.notices.listen((notice) {
      if (platform.allowed && platform.inBackground) {
        platform.show(notice.title, notice.body, tag: notice.chat);
      }
    });
