import 'dart:async';

import 'package:flutter/material.dart';

import 'core/identity_store.dart';
import 'ui/app.dart';
import 'ui/app_controller.dart';

void main() {
  final controller = AppController(const IdentityStore(PlatformSecretStore()));
  unawaited(controller.restore());
  runApp(MorandubaApp(controller: controller));
}
