import 'package:flutter/material.dart';

/// MedThru brand palette + light/dark themes, kept in one place so every
/// screen stays visually consistent.
///
/// Brand: deep navy surfaces with a vivid blue accent, white cards, and
/// pastel icon tiles.
class MedThruTheme {
  // Core brand colors.
  static const navy = Color(0xFF0B1D36); // dark sections, app bar
  static const navyDeep = Color(0xFF071426); // gradient end
  static const blue = Color(0xFF2E9BF0); // primary accent
  static const blueBright = Color(0xFF3BA4F5); // accent on dark
  static const danger = Color(0xFFDC2626);

  // Pastel tiles used behind feature icons.
  static const tileBlue = Color(0xFFE3F0FD);
  static const tileGreen = Color(0xFFDFF5E6);
  static const tileRed = Color(0xFFFDE7EA);
  static const tilePurple = Color(0xFFEEE7FD);

  // Icon colors that sit on those tiles.
  static const iconBlue = Color(0xFF1D7FD4);
  static const iconGreen = Color(0xFF19A05B);
  static const iconRed = Color(0xFFE0384E);
  static const iconPurple = Color(0xFF6D48D7);

  static ThemeData light() => _build(_lightScheme);
  static ThemeData dark() => _build(_darkScheme);

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: blue,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE3F0FD),
    onPrimaryContainer: navy,
    secondary: navy,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFE3F0FD),
    onSecondaryContainer: navy,
    error: danger,
    onError: Colors.white,
    surface: Color(0xFFF1F6FE), // pale blue page background
    onSurface: Color(0xFF0F2547), // navy text
    surfaceContainerLow: Colors.white, // cards
    surfaceContainerHighest: Color(0xFFE6EEF9),
    onSurfaceVariant: Color(0xFF5B6B7F), // muted body text
    outlineVariant: Color(0xFFDCE6F2),
    outline: Color(0xFFB9C8DA),
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: blueBright,
    onPrimary: Color(0xFF06111F),
    primaryContainer: Color(0xFF123A5E),
    onPrimaryContainer: Color(0xFFD6EAFB),
    secondary: blueBright,
    onSecondary: Color(0xFF06111F),
    secondaryContainer: Color(0xFF123A5E),
    onSecondaryContainer: Color(0xFFD6EAFB),
    error: Color(0xFFFF6B6B),
    onError: Color(0xFF3A0509),
    surface: navy,
    onSurface: Color(0xFFE8F0F9),
    surfaceContainerLow: Color(0xFF12294A), // cards on navy
    surfaceContainerHighest: Color(0xFF1B3559),
    onSurfaceVariant: Color(0xFF9DB2CA),
    outlineVariant: Color(0xFF22406B),
    outline: Color(0xFF3A5C87),
  );

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // The app bar stays navy in both themes — it's the brand bar.
      appBarTheme: const AppBarTheme(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: Colors.white),
        actionsIconTheme: IconThemeData(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.brightness == Brightness.light
            ? Colors.white
            : scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: navy,
        contentTextStyle: TextStyle(color: Colors.white),
      ),
    );
  }
}
