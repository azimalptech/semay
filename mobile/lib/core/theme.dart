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

  /// The read ("seen") tick under a sent message. Unused since chat moved to
  /// Instagram's model — there are no per-message ticks any more, only the one
  /// Sending…/Sent/Seen line under the newest message (see
  /// chat_thread_screen.dart's MessageStatusLine) — kept because it is the
  /// colour to reach for if a per-message read mark is ever wanted again.
  static const Color readTick = Color(0xFF34B7F1);

  /// Store Detail's "Call" button — deliberately not [brand]; a call action
  /// reads as green everywhere else in the app (dialer icons, etc.) too.
  // Figma state-colors/success. Was 0xFF22C55E, which did not match the design.
  static const Color callGreen = Color(0xFF00C950);

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

  /// Bundled in pubspec.yaml (SIL OFL — assets/fonts/Geist-OFL.txt). Applied via
  /// ThemeData.fontFamily below, so individual styles don't repeat it.
  ///
  /// Letter-spacing throughout this class is Figma's -2% expressed in logical
  /// pixels (15 * -0.02 = -0.3, 13 * -0.02 = -0.26, and so on).
  static const String fontFamily = 'Geist';

  static TextStyle get titleLarge => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  /// Figma "Title/Small" — store name on the store detail header.
  static TextStyle get titleSmall => TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.36,
    color: AppColors.textPrimary,
  );

  /// Figma "Body/Large Bold" — the stat numbers (245 / 342 / 24.34K).
  static TextStyle get bodyLargeBold => TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.34,
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

/// Type scale for the chat surfaces only — the conversation thread
/// (chat_thread_screen.dart) and the inbox (chat_list_screen.dart).
///
/// WHY THIS IS SCOPED, and not a bump to [AppTypography]: the owner reported
/// that chat text reads far smaller than WhatsApp/Instagram, and it does —
/// chat was drawing message bodies at `bodyMedium` (15) and every secondary
/// line at `caption` (11), while both of those messengers run message text at
/// ~16, timestamps at ~12, and an inbox preview at ~14 under a ~17 name. But
/// `bodyMedium`, `bodySmall` and `caption` are the Figma body scale for the
/// WHOLE app — feed, profile, orders, leaderboard, settings — all of which the
/// owner has already seen and approved. Raising them there would resize
/// screens nobody asked about. So chat gets its own group, and only the chat
/// widgets point at it; every other screen keeps the Figma scale untouched.
///
/// Sizes are plain logical-pixel `fontSize`s, exactly like [AppTypography],
/// so the platform's text-size accessibility setting still scales them: the
/// app never overrides `MediaQuery.textScaler` anywhere, so Flutter's default
/// scaling applies. Nothing here pins a box height to a font size, which is
/// what would break at a large system scale.
///
/// Letter-spacing keeps the Figma -2% rule (16 * -0.02 = -0.32, and so on).
class ChatTypography {
  ChatTypography._();

  /// The message body inside a bubble. 16 with a 1.3 line height — Instagram
  /// bubbles read large as much from the leading and the bubble padding as
  /// from the glyph size, so the height is part of the fix, not decoration.
  static TextStyle get message => TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
    color: AppColors.textPrimary,
  );

  /// The quoted reply block inside a bubble. Deliberately a step under
  /// [message] but nowhere near the old 11 — at 11 beside a 16 body it read
  /// as a rendering fault.
  static TextStyle get quote => TextStyle(
    fontSize: 13,
    height: 1.25,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.26,
    color: AppColors.textSecondary,
  );

  /// Clock under a bubble (HH:mm).
  static TextStyle get bubbleTime => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
    color: AppColors.textSecondary,
  );

  /// "Ugradylýar… / Ugradyldy / Görüldi" under the newest own message, and the
  /// red "not sent" label — same size as the clock they sit beside.
  static TextStyle get status => bubbleTime;

  /// Day separator between message groups.
  static TextStyle get dateDivider => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.26,
    color: AppColors.textSecondary,
  );

  /// The thread app-bar's second line — "ýazýar…" / "Birikdirilýär…".
  static TextStyle get threadSubtitle => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.26,
    color: AppColors.textSecondary,
  );

  /// Composer input text and its hint.
  static TextStyle get composer => TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
    color: AppColors.textPrimary,
  );

  /// Inbox row: the store / customer name.
  static TextStyle get inboxName => TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.34,
    color: AppColors.textPrimary,
  );

  /// Inbox row: the last-message preview, and "ýazýar…" in its place.
  static TextStyle get inboxPreview => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.28,
    color: AppColors.textSecondary,
  );

  /// Inbox row: the timestamp on the right of the preview line. Kept a step
  /// under the preview so a long Turkmen name plus "Today, 17 Sep" still fits
  /// on one row.
  static TextStyle get inboxTime => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
    color: AppColors.textMuted,
  );
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    // Every text style in the Figma file is Geist. Set once here so it applies
    // app-wide rather than per-widget — previously unset, so the whole app
    // rendered in Roboto and no screen could match the design.
    fontFamily: AppTypography.fontFamily,
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
    fontFamily: AppTypography.fontFamily,
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
