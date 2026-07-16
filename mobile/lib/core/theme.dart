import 'package:flutter/material.dart';

/// Design tokens pulled from the SeMay Figma file
/// (https://www.figma.com/design/OI1BiSUDnZbc7biI19abwD/SeMay), Chat screens.
/// Typography matches Figma's Geist sizes/weights/letter-spacing, but keeps
/// the platform default font family — Geist isn't bundled in this project.
class AppColors {
  AppColors._();

  static const Color backgroundPrimary = Color(0xFFF7F5F2);
  static const Color backgroundCard = Colors.white;
  static const Color borderDivider = Color(0xFFEAE6DF);
  static const Color brand = Color(0xFF934D8E);
  static const Color buttonMuted = Color(0xFFCECECE);
  static const Color textPrimary = Color(0xFF2E2D2A);
  static const Color textSecondary = Color(0xFF636363);
  static const Color textMuted = Color(0xFF9B9B9B);
  static const Color textOnPrimary = Colors.white;
  static const Color error = Color(0xFFF44F3E);

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

  static const titleLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const bodyMediumSemibold = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  static const bodyMedium = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  static const bodySmall = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.26,
    color: AppColors.textPrimary,
  );

  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.24,
    color: AppColors.textSecondary,
  );

  static const caption = TextStyle(
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
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.backgroundCard,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: AppTypography.titleLarge,
        ),
        dividerColor: AppColors.borderDivider,
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.brand,
          brightness: Brightness.dark,
        ),
      );
}
