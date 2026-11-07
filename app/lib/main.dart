import 'dart:async';

import 'package:flutter/material.dart';

import 'core/identity_store.dart';
import 'core/push/push.dart';
import 'ui/app.dart';
import 'ui/app_controller.dart';
import 'ui/files/files.dart';
import 'ui/notifications/notifications.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadNotifications();
  await startPush(showPushRing);
  // UnifiedPush woke the app only to deliver a push.
  if (args.contains('--unifiedpush-bg')) return;
  setUpMediaPlayback();
  final controller = AppController(const PlatformSecretStore());
  unawaited(controller.restore());
  runApp(MorandubaApp(controller: controller));
}
