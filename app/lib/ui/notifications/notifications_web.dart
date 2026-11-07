import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get supported => true;

bool get allowed => web.Notification.permission == 'granted';

bool get inBackground => web.document.hidden;

Future<bool> ask() async {
  final answer = await web.Notification.requestPermission().toDart;
  return answer.toDart == 'granted';
}

/// One notification per chat ([tag]); a newer message replaces it.
void show(String title, String body, {required String tag}) {
  web.Notification(
    title,
    web.NotificationOptions(
      body: body.length > 140 ? '${body.substring(0, 140)}…' : body,
      tag: tag,
      icon: 'icons/Icon-192.png',
    ),
  );
}
