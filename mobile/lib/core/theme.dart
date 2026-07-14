import 'package:flutter/material.dart';

// Placeholder tokens only — no Figma file has been provided yet.
// Replace with real colors/typography from the Figma design once shared,
// per docs/01_ARCHITECTURE.md §7.
class AppTheme {
  AppTheme._();

  static const Color _placeholderSeed = Color(0xFF6750A4);

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _placeholderSeed,
          brightness: Brightness.light,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _placeholderSeed,
          brightness: Brightness.dark,
        ),
      );
}
