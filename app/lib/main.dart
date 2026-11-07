import 'dart:async';

import 'package:flutter/material.dart';

import 'core/identity_store.dart';
import 'ui/app.dart';
import 'ui/app_controller.dart';
import 'ui/files/files.dart';
import 'ui/notifications/notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setUpMediaPlayback();
  await loadNotifications();
  final controller = AppController(const PlatformSecretStore());
  unawaited(controller.restore());
  runApp(MorandubaApp(controller: controller));
}
