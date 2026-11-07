import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'manga.dart';
import 'theme.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _key = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    try {
      await widget.controller.import(_key.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Entrance(child: _Hero()),
                  const SizedBox(height: 24),
                  Entrance(
                    index: 1,
                    child: Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('NEW HERE?', style: text.headlineSmall),
                          const SizedBox(height: 8),
                          Text(
                            'No account and no email. Your identity is a '
                            'key made on this device, and only you hold it.',
                            style: text.bodyLarge,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: widget.controller.create,
                            child: const Text('Create my key'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Entrance(
                    index: 2,
                    child: Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('ALREADY HAVE ONE?', style: text.headlineSmall),
                          const SizedBox(height: 12),
                          LabeledField(
                            label: 'Secret key',
                            hint: 'nsec1… or 64-character hex',
                            controller: _key,
                            obscure: true,
                            monospace: true,
                            error: _error,
                            onSubmitted: (_) => _import(),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _import,
                            child: const Text('Import key'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: MangaShape.borderRadius,
        border: Border.all(width: MangaShape.stroke),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          MangaShape.radius - MangaShape.stroke,
        ),
        child: SizedBox(
          height: 240,
          child: SpeedLines(
            child: Stack(
              children: [
                const Positioned(top: 16, right: 18, child: Sfx('SHHH!')),
                Align(
                  alignment: const Alignment(0, 0.35),
                  child: AngledPanel(
                    child: Container(
                      color: MangaColors.paper,
                      padding: const EdgeInsets.fromLTRB(36, 14, 36, 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('MORANDUBA', style: text.displayMedium),
                          Text(
                            'stories told only to your circle',
                            style: text.titleSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
