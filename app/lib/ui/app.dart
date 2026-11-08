import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'call_bar.dart';
import 'home_page.dart';
import 'hotkeys.dart';
import 'incoming_call.dart';
import 'manga.dart';
import 'onboarding_page.dart';
import 'theme.dart';

class MorandubaApp extends StatefulWidget {
  const MorandubaApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<MorandubaApp> createState() => _MorandubaAppState();
}

class _MorandubaAppState extends State<MorandubaApp> {
  final _navigator = GlobalKey<NavigatorState>();

  AppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moranduba',
      navigatorKey: _navigator,
      builder: (context, child) => HotkeyLayer(
        controller: controller,
        child: CallBarLayer(
          controller: controller,
          navigator: _navigator,
          child: IncomingCallLayer(
            controller: controller,
            navigator: _navigator,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
      theme: mangaTheme(),
      themeMode: ThemeMode.light,
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => switch (controller.stage) {
          AppStage.loading => const _Connecting(),
          AppStage.onboarding => OnboardingPage(controller: controller),
          AppStage.ready => HomePage(
            session: controller.session!,
            onLogout: controller.logout,
          ),
          AppStage.failed => Scaffold(
            body: EmptyState(
              icon: Icons.wifi_off_outlined,
              title: 'NO SIGNAL',
              message: 'Could not reach the relays: ${controller.error}',
              action: FilledButton(
                onPressed: controller.restore,
                child: const Text('Try again'),
              ),
            ),
          ),
        },
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 280,
        child: Panel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CONNECTING…',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              const Skeleton(),
              const SizedBox(height: 10),
              const Skeleton(width: 180),
              const SizedBox(height: 10),
              const Skeleton(width: 120),
            ],
          ),
        ),
      ),
    ),
  );
}
