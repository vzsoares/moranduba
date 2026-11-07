import 'package:flutter/material.dart';

/// Tokens from the "Manga Instructional Comic" DESIGN.md. Light only:
/// the spec has no dark palette.
abstract final class MangaColors {
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF000000);
  static const charcoal = Color(0xFF1A1A1A);
  static const tone = Color(0xFFCCCCCC);
  // The spec only says "semantic red"; kept under its 80% saturation cap.
  static const error = Color(0xFFB3261E);
}

abstract final class MangaFonts {
  // Stand-ins for Manga Temple, which has no openly licensed font file.
  static const display = 'Bangers';
  static const body = 'ComicNeue';
  static const mono = 'JetBrainsMono';
}

abstract final class MangaShape {
  static const radius = 8.0;
  static const stroke = 2.0;
  static final borderRadius = BorderRadius.circular(radius);
  static const panelShadow = [
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 2), blurRadius: 12),
  ];
}

abstract final class MangaMotion {
  static const entry = Duration(milliseconds: 420);
  static const stagger = Duration(milliseconds: 80);
  static const hover = Duration(milliseconds: 200);
  static const page = Duration(milliseconds: 200);
}

TextStyle displayStyle(double size) => TextStyle(
  fontFamily: MangaFonts.display,
  fontSize: size,
  height: 1.05,
  letterSpacing: 1.2,
  color: MangaColors.ink,
);

const monoStyle = TextStyle(
  fontFamily: MangaFonts.mono,
  fontSize: 13,
  color: MangaColors.ink,
);

ThemeData mangaTheme() {
  const scheme = ColorScheme.light(
    primary: MangaColors.charcoal,
    onPrimary: MangaColors.paper,
    secondary: MangaColors.ink,
    onSecondary: MangaColors.paper,
    surface: MangaColors.paper,
    onSurface: MangaColors.ink,
    surfaceContainerHighest: MangaColors.paper,
    outline: MangaColors.ink,
    outlineVariant: MangaColors.tone,
    error: MangaColors.error,
    onError: MangaColors.paper,
  );
  const panelSide = BorderSide(width: MangaShape.stroke);
  final rounded = RoundedRectangleBorder(borderRadius: MangaShape.borderRadius);
  final panel = RoundedRectangleBorder(
    borderRadius: MangaShape.borderRadius,
    side: panelSide,
  );
  const label = TextStyle(
    fontFamily: MangaFonts.body,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
  );

  Color hovered(Set<WidgetState> states, Color base) =>
      states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.pressed)
      ? Color.lerp(base, MangaColors.ink, 0.08)!
      : base;

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: MangaColors.paper,
    fontFamily: MangaFonts.body,
    textTheme: TextTheme(
      displayLarge: displayStyle(64),
      displayMedium: displayStyle(52),
      displaySmall: displayStyle(40),
      headlineMedium: displayStyle(36),
      headlineSmall: displayStyle(28),
      titleLarge: displayStyle(24),
      titleMedium: label.copyWith(fontSize: 16),
      titleSmall: label,
      bodyLarge: const TextStyle(fontSize: 16, height: 1.6),
      bodyMedium: const TextStyle(fontSize: 15, height: 1.5),
      bodySmall: const TextStyle(fontSize: 13, height: 1.4),
      labelLarge: label,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: MangaColors.paper,
      foregroundColor: MangaColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: displayStyle(30),
      shape: const Border(bottom: panelSide),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: MangaColors.ink,
      unselectedLabelColor: Color(0x8C000000),
      labelStyle: label,
      unselectedLabelStyle: TextStyle(
        fontFamily: MangaFonts.body,
        fontSize: 14,
      ),
      indicatorColor: MangaColors.charcoal,
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(width: 4, color: MangaColors.charcoal),
      ),
      dividerColor: MangaColors.ink,
      dividerHeight: MangaShape.stroke,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? MangaColors.tone
              : hovered(s, MangaColors.charcoal),
        ),
        foregroundColor: const WidgetStatePropertyAll(MangaColors.paper),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
        shape: WidgetStatePropertyAll(rounded),
        textStyle: const WidgetStatePropertyAll(label),
        elevation: const WidgetStatePropertyAll(0),
        animationDuration: MangaMotion.hover,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(MangaColors.ink),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? const Color(0x0F000000)
              : Colors.transparent,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(width: 1.5, color: MangaColors.charcoal),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
        shape: WidgetStatePropertyAll(rounded),
        textStyle: const WidgetStatePropertyAll(label),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: MangaColors.ink,
        textStyle: label,
        shape: rounded,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: MangaColors.charcoal,
      foregroundColor: MangaColors.paper,
      elevation: 0,
      highlightElevation: 0,
      hoverElevation: 0,
      focusElevation: 0,
      shape: panel,
      extendedTextStyle: label,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MangaColors.paper,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: const TextStyle(color: Color(0x8C000000)),
      border: OutlineInputBorder(
        borderRadius: MangaShape.borderRadius,
        borderSide: const BorderSide(color: MangaColors.ink),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: MangaShape.borderRadius,
        borderSide: const BorderSide(color: MangaColors.ink),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: MangaShape.borderRadius,
        borderSide: const BorderSide(color: MangaColors.charcoal, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: MangaShape.borderRadius,
        borderSide: const BorderSide(color: MangaColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: MangaShape.borderRadius,
        borderSide: const BorderSide(color: MangaColors.error, width: 2),
      ),
      errorStyle: const TextStyle(color: MangaColors.error, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MangaColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: panel,
      titleTextStyle: displayStyle(28),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MangaColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      dragHandleColor: MangaColors.ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MangaShape.radius),
        ),
        side: panelSide,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MangaColors.charcoal,
      contentTextStyle: label.copyWith(color: MangaColors.paper),
      behavior: SnackBarBehavior.floating,
      shape: rounded,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: MangaColors.ink,
      thickness: MangaShape.stroke,
    ),
    iconTheme: const IconThemeData(color: MangaColors.ink),
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeTransitions(),
        TargetPlatform.iOS: _FadeTransitions(),
        TargetPlatform.macOS: _FadeTransitions(),
        TargetPlatform.linux: _FadeTransitions(),
        TargetPlatform.windows: _FadeTransitions(),
        TargetPlatform.fuchsia: _FadeTransitions(),
      },
    ),
  );
}

class _FadeTransitions extends PageTransitionsBuilder {
  const _FadeTransitions();

  @override
  Duration get transitionDuration => MangaMotion.page;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}
