import 'dart:async';

import 'package:flutter/material.dart';

import 'core/identity_store.dart';
import 'ui/app.dart';
import 'ui/app_controller.dart';
import 'ui/files/files.dart';

void main() {
  setUpMediaPlayback();
  final controller = AppController(const PlatformSecretStore());
  unawaited(controller.restore());
  runApp(MorandubaApp(controller: controller));
}
