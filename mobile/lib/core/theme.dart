import 'package:flutter/material.dart';

/// Design tokens pulled from the SeMay Figma file
/// (https://www.figma.com/design/OI1BiSUDnZbc7biI19abwD/SeMay), Chat screens.
/// Typography matches Figma's Geist sizes/weights/letter-spacing, but keeps
/// the platform default font family — Geist isn't bundled in this project.
///
/// Every screen in this app reads colors as `AppColors.textPrimary` etc.
/// directly rather than through `Theme.of(context)`, so dark mode is wired
/// up here as brightness-aware *getters* (set once, app-wide, by
/// AppColors.setDark) instead of the usual ThemeData/ColorScheme route —
/// switching that many call sites over to context-based lookups would be a
/// much larger, separate refactor. main.dart forces a full widget rebuild
/// when the flag flips (see its ValueKey), which is what makes already-built
/// widgets actually repaint with the new getter values.
class AppColors {
  AppColors._();

  static bool _isDark = false;
  static bool get isDark => _isDark;
  static void setDark(bool value) => _isDark = value;

  static Color get backgroundPrimary =>
      _isDark ? const Color(0xFF121212) : const Color(0xFFF7F5F2);
  static Color get backgroundCard =>
      _isDark ? const Color(0xFF1E1E1E) : Colors.white;
  static Color get borderDivider =>
      _isDark ? const Color(0xFF2C2C2C) : const Color(0xFFEAE6DF);
  static const Color brand = Color(0xFF934D8E);
  static Color get buttonMuted =>
      _isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCECECE);
  static Color get textPrimary =>
      _isDark ? const Color(0xFFF2F0EE) : const Color(0xFF2E2D2A);
  static Color get textSecondary =>
      _isDark ? const Color(0xFFB5B3B0) : const Color(0xFF636363);
  static Color get textMuted =>
      _isDark ? const Color(0xFF8A8886) : const Color(0xFF9B9B9B);
  static const Color textOnPrimary = Colors.white;
  static const Color error = Color(0xFFF44F3E);

  /// Store Detail's "Call" button — deliberately not [brand]; a call action
  /// reads as green everywhere else in the app (dialer icons, etc.) too.
  static const Color callGreen = Color(0xFF22C55E);

  /// Story-ring accent (Homepage story bar) — distinct from `brand`.
  static const Color storyRing = Color(0xFFFF08ED);
  static const Color overlayAlphaBlack = Color(0x66000000);

  /// "Brand Graadient Story" (sic — Figma style name): sweep used for the
  /// unseen story ring; seen rings fall back to [buttonMuted].
  static const List<Color> storyGradient = [
    Color(0xFF934D8E),
    Color(0xFFFF08ED),
    Color(0xFFFFA0F5),
    Color(0xFF934D8E),
  ];
}

class AppTypography {
  AppTypography._();

  static TextStyle get titleLarge => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodyMediumSemibold => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodyMedium => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodySmall => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.26,
    color: AppColors.textPrimary,
  );

  static TextStyle get label => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.24,
    color: AppColors.textSecondary,
  );

  static TextStyle get caption => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.22,
    color: AppColors.textSecondary,
  );

  static const buttonSmall = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.26,
  );

  static const chip = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.22,
  );
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.backgroundPrimary,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.light,
      primary: AppColors.brand,
      onPrimary: AppColors.textOnPrimary,
      surface: AppColors.backgroundCard,
      error: AppColors.error,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.backgroundCard,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppTypography.titleLarge,
    ),
    dividerColor: AppColors.borderDivider,
  );

  // Only ever built while AppColors.isDark is true (see main.dart), so these
  // getters correctly resolve to the dark palette above.
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.backgroundPrimary,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.dark,
      primary: AppColors.brand,
      onPrimary: AppColors.textOnPrimary,
      surface: AppColors.backgroundCard,
      error: AppColors.error,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.backgroundCard,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppTypography.titleLarge,
    ),
    dividerColor: AppColors.borderDivider,
  );
}
