import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

/// Radial focus lines converging on the center, clear in the middle.
class SpeedLines extends StatelessWidget {
  const SpeedLines({super.key, this.child, this.lines = 72, this.seed = 7});

  final Widget? child;
  final int lines;
  final int seed;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _SpeedLinesPainter(lines: lines, seed: seed),
    child: child,
  );
}

class _SpeedLinesPainter extends CustomPainter {
  _SpeedLinesPainter({required this.lines, required this.seed});

  final int lines;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final center = size.center(Offset.zero);
    final outer = size.longestSide;
    final paint = Paint()..color = MangaColors.ink;
    for (var i = 0; i < lines; i++) {
      final angle = (i / lines) * 2 * math.pi + random.nextDouble() * 0.05;
      final spread = 0.004 + random.nextDouble() * 0.012;
      // Each line is a thin wedge that stops short of an inner ellipse.
      final inner = 0.42 + random.nextDouble() * 0.2;
      final tip = Offset(
        center.dx + math.cos(angle) * size.width / 2 * inner,
        center.dy + math.sin(angle) * size.height / 2 * inner,
      );
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          center.dx + math.cos(angle - spread) * outer,
          center.dy + math.sin(angle - spread) * outer,
        )
        ..lineTo(
          center.dx + math.cos(angle + spread) * outer,
          center.dy + math.sin(angle + spread) * outer,
        )
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SpeedLinesPainter old) =>
      old.lines != lines || old.seed != seed;
}

/// Halftone dot screen, laid on a 45° grid like printed screentone.
class Screentone extends StatelessWidget {
  const Screentone({
    super.key,
    this.child,
    this.spacing = 7,
    this.dot = 1.4,
    this.color = MangaColors.tone,
  });

  final Widget? child;
  final double spacing;
  final double dot;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ScreentonePainter(spacing: spacing, dot: dot, color: color),
    child: child,
  );
}

class _ScreentonePainter extends CustomPainter {
  _ScreentonePainter({
    required this.spacing,
    required this.dot,
    required this.color,
  });

  final double spacing;
  final double dot;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var row = 0;
    for (var y = 0.0; y < size.height + spacing; y += spacing, row++) {
      final offset = row.isOdd ? spacing / 2 : 0.0;
      for (var x = offset; x < size.width + spacing; x += spacing) {
        canvas.drawCircle(Offset(x, y), dot, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ScreentonePainter old) =>
      old.spacing != spacing || old.dot != dot || old.color != color;
}

/// A comic panel: paper fill, ink border, soft drop shadow.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = MangaColors.paper,
    this.toned = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final bool toned;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: MangaShape.borderRadius,
        border: Border.all(width: MangaShape.stroke),
        boxShadow: MangaShape.panelShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          MangaShape.radius - MangaShape.stroke,
        ),
        child: toned ? Screentone(child: content) : content,
      ),
    );
  }
}

/// Panel cut as a trapezoid: polygon(0 0, 100% 0, 95% 100%, 5% 100%).
class AngledPanel extends StatelessWidget {
  const AngledPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ClipPath(clipper: _TrapezoidClipper(), child: child);
}

class _TrapezoidClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width * 0.95, size.height)
    ..lineTo(size.width * 0.05, size.height)
    ..close();

  @override
  bool shouldReclip(_TrapezoidClipper old) => false;
}

/// Sound-effect lettering: tilted display type with a paper outline.
class Sfx extends StatelessWidget {
  const Sfx(this.text, {super.key, this.size = 56, this.angle = -0.12});

  final String text;
  final double size;
  final double angle;

  @override
  Widget build(BuildContext context) {
    final base = displayStyle(size).copyWith(letterSpacing: 3);
    return Transform.rotate(
      angle: angle,
      child: Stack(
        children: [
          Text(
            text,
            style: base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = size / 7
                ..strokeJoin = StrokeJoin.round
                ..color = MangaColors.paper,
            ),
          ),
          Text(text, style: base),
        ],
      ),
    );
  }
}

/// Speech balloon with a tail toward the speaker.
class SpeechBubble extends StatelessWidget {
  const SpeechBubble({super.key, required this.text, required this.outgoing});

  final String text;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final fill = outgoing ? MangaColors.charcoal : MangaColors.paper;
    final ink = outgoing ? MangaColors.paper : MangaColors.ink;
    return CustomPaint(
      painter: _BubblePainter(fill: fill, outgoing: outgoing),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          outgoing ? 16 : 26,
          10,
          outgoing ? 26 : 16,
          12,
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: ink),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({required this.fill, required this.outgoing});

  final Color fill;
  final bool outgoing;

  static const _tail = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Rect.fromLTRB(
      outgoing ? 0 : _tail,
      0,
      outgoing ? size.width - _tail : size.width,
      size.height,
    );
    final bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(body, const Radius.circular(18)));
    final baseY = size.height - 22;
    final tail = Path();
    if (outgoing) {
      tail
        ..moveTo(body.right - 2, baseY)
        ..lineTo(size.width, size.height - 4)
        ..lineTo(body.right - 14, size.height - 1)
        ..close();
    } else {
      tail
        ..moveTo(body.left + 2, baseY)
        ..lineTo(0, size.height - 4)
        ..lineTo(body.left + 14, size.height - 1)
        ..close();
    }
    final shape = Path.combine(PathOperation.union, bubble, tail);
    canvas
      ..drawPath(shape, Paint()..color = fill)
      ..drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = MangaShape.stroke
          ..color = MangaColors.ink,
      );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.fill != fill || old.outgoing != outgoing;
}

/// Fade + 16px rise, staggered by [index].
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: MangaMotion.entry,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(MangaMotion.stagger * widget.index.clamp(0, 8), () {
      if (mounted) unawaited(_controller.forward());
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    builder: (context, child) => Opacity(
      opacity: _curve.value,
      child: Transform.translate(
        offset: Offset(0, 16 * (1 - _curve.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}

/// Loading placeholder; the spec rules out circular spinners.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width = double.infinity, this.height = 14});

  final double width;
  final double height;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        gradient: LinearGradient(
          begin: Alignment(-1 + 3 * _controller.value - 1, 0),
          end: Alignment(3 * _controller.value - 1, 0),
          colors: const [MangaColors.tone, MangaColors.paper, MangaColors.tone],
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Entrance(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(width: MangaShape.stroke),
                  ),
                  child: ClipOval(
                    child: Screentone(
                      child: Center(child: Icon(icon, size: 40)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(title, style: text.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: text.bodyLarge,
                ),
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text field with its label above, never floating.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.error,
    this.obscure = false,
    this.autofocus = false,
    this.monospace = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? error;
  final bool obscure;
  final bool autofocus;
  final bool monospace;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        obscureText: obscure,
        autofocus: autofocus,
        style: monospace ? monoStyle : null,
        decoration: InputDecoration(hintText: hint, errorText: error),
        onSubmitted: onSubmitted,
      ),
    ],
  );
}

/// One row in a list: a panel with avatar, title, line and trailing actions.
class RowPanel extends StatelessWidget {
  const RowPanel({
    super.key,
    required this.title,
    required this.line,
    this.icon = Icons.person_outline,
    this.trailing,
    this.onTap,
  });

  final Widget title;
  final String line;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Panel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Avatar(icon: icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: 2),
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium,
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Round avatar placeholder: ink ring over screentone.
class Avatar extends StatelessWidget {
  const Avatar({super.key, this.icon = Icons.person_outline});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(width: MangaShape.stroke),
    ),
    child: ClipOval(
      child: Screentone(
        spacing: 5,
        dot: 1,
        child: Center(child: Icon(icon, size: 22)),
      ),
    ),
  );
}

/// Brand mark: a listener-speaker in profile, inked in [color].
class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 32, this.color = MangaColors.ink});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/brand/logo.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    semanticsLabel: 'Moranduba',
  );
}
