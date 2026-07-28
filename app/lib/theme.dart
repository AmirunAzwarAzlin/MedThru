import 'package:flutter/material.dart';

/// MedThru brand palette + themes, kept in one place so every screen stays
/// visually consistent.
///
/// Direction — "warm calm": a soft, warm off-white canvas with crisp white
/// cards that read as gently floating (whisper-soft warm hairlines rather than
/// hard borders), warm-charcoal display type, a periwinkle-purple brand accent
/// and a lime highlight for positive figures. Red stays reserved for the single
/// emergency affordance. Friendly and reassuring at rest; the emergency band is
/// the one loud thing.
///
/// The app is light-first. The dark theme is kept coherent as a fallback.
class MedThruTheme {
  // --- Warm light surfaces (the star) ---
  static const cream = Color(0xFFF4F2EE); // scaffold: warm off-white paper
  static const card = Color(0xFFFFFFFF); // cards
  static const sand = Color(0xFFEBE7E0); // secondary tiles / inputs (warm)
  static const ink = Color(0xFF272430); // warm charcoal text
  static const inkMuted = Color(0xFF787280); // warm muted body text
  static const hairlineL = Color(0xFFEAE5DD); // whisper-soft warm card borders
  static const lineL = Color(0xFFD6D0C6); // stronger warm outlines

  // --- Dark surfaces (fallback theme) ---
  static const bg = Color(0xFF0E0E18);
  static const surface = Color(0xFF171725);
  static const surfaceHigh = Color(0xFF1F1F30);
  static const hairline = Color(0xFF2A2A3C);
  static const line = Color(0xFF3A3A50);

  // Kept for the several screens that still import these names — the dark
  // brand surfaces used by hero gradients and the like.
  static const navy = Color(0xFF14141F);
  static const navyDeep = Color(0xFF090910);

  // --- Accents ---
  // Periwinkle purple is the brand accent (the `coral`/`blue` names are kept
  // only because the codebase imports them widely as the brand alias). A soft
  // blue is the secondary accent; lime is the highlight for positive figures.
  static const coral = Color(0xFF6C63C7); // brand accent — active nav, actions
  static const coralBright = Color(0xFF8F86E8); // punchier, for dark surfaces
  static const coralDeep = Color(0xFF4E44A8);
  static const blue = coral; // brand accent alias
  static const blueBright = coralBright;
  static const blueDeep = coralDeep;

  static const teal = Color(0xFF5B8DEF); // secondary accent — soft blue
  static const tealDeep = Color(0xFF3A6BD0);

  static const green = Color(0xFF3E9E7E); // success / within range
  static const greenBright = Color(0xFF56C0A0);
  static const greenDeep = Color(0xFF2A6E58);

  // Lime highlight — positive deltas and the accent pop from the reference.
  // Pair with dark text; it is too bright for white type.
  static const lime = Color(0xFFC7ED4B);
  static const limeDeep = Color(0xFF9BBE1F);

  static const amber = Color(0xFFE49409); // warm highlight / caution
  // Emergency stays a deep crimson, held clearly apart from the brand so an
  // alert never blends into the accent.
  static const danger = Color(0xFFCE3A2B); // emergency red

  // Emergency band gradient — a deep crimson so it reads unmistakably as an
  // alert, distinct from coral brand surfaces.
  static const bandRed1 = Color(0xFFC0322A);
  static const bandRed2 = Color(0xFF8F211C);

  // Text roles that resolve per brightness are read from the scheme; these are
  // the shared brand values.
  static const text = ink;
  static const muted = inkMuted;

  // --- Accent set for the action-tile grid (four distinct hues) ---
  // `icon*` is the saturated accent; `tile*` is the pale wash used as the tile
  // background on light surfaces (see [ActionTile]).
  static const iconGreen = green;
  static const iconBlue = teal; // soft-blue secondary
  static const iconRed = danger;
  static const iconPurple = coral; // brand purple

  static const tileGreen = Color(0xFFD8EDE5);
  static const tileBlue = Color(0xFFDCE6FB); // pale blue
  static const tileRed = Color(0xFFF6DAD5);
  static const tilePurple = Color(0xFFE6E2FB); // pale purple

  // A soft, warm two-layer shadow that lifts white cards off the paper canvas
  // — an ambient blur plus a tight contact shadow. Deliberately faint (~6% /
  // 4%) so cards read as gently floating, not dropped. Barely visible on the
  // dark fallback, which separates cards by surface colour instead.
  static const softShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0F171013), blurRadius: 16, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x0A171013), blurRadius: 3, offset: Offset(0, 1)),
  ];

  static ThemeData light() => _build(_lightScheme);
  static ThemeData dark() => _build(_darkScheme);

  // Cool-grey scheme — the default, tuned for this design.
  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: coral,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE6E2FB),
    onPrimaryContainer: Color(0xFF241A5E),
    secondary: teal,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFDCE6FB),
    onSecondaryContainer: Color(0xFF10306B),
    tertiary: amber,
    onTertiary: Colors.white,
    error: danger,
    onError: Colors.white,
    surface: cream,
    onSurface: ink,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: card, // cards
    surfaceContainer: Color(0xFFF0EDE7),
    surfaceContainerHigh: sand,
    surfaceContainerHighest: Color(0xFFE4DFD6),
    onSurfaceVariant: inkMuted,
    outlineVariant: hairlineL,
    outline: lineL,
  );

  // Dark fallback, retuned to the purple accent so a device forced to dark
  // still reads as the same product.
  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: coralBright,
    onPrimary: Color(0xFF1A1340),
    primaryContainer: Color(0xFF3B327A),
    onPrimaryContainer: Color(0xFFE4E1FA),
    secondary: Color(0xFF86A9F0),
    onSecondary: Color(0xFF0A1F45),
    secondaryContainer: Color(0xFF23386B),
    onSecondaryContainer: Color(0xFFD3E1FB),
    tertiary: Color(0xFFF5A524),
    onTertiary: Color(0xFF2A1B00),
    error: danger,
    onError: Color(0xFF2A0708),
    surface: bg,
    onSurface: Color(0xFFEDEEF5),
    surfaceContainerLowest: Color(0xFF090910),
    surfaceContainerLow: surface,
    surfaceContainer: Color(0xFF1A1A28),
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: Color(0xFF26263A),
    onSurfaceVariant: Color(0xFF8E92A6),
    outlineVariant: hairline,
    outline: line,
  );

  static ThemeData _build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final base = isDark ? ThemeData.dark() : ThemeData.light();

    // Primary confirm actions carry the coral brand (the reference leads with
    // coral pills and buttons), in both themes.
    final ctaBg = scheme.primary;
    final ctaFg = scheme.onPrimary;

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _textTheme(base.textTheme, scheme),
      // The app bar melts into the page (seamless top bar) rather than being a
      // separate coloured brand bar.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shadowColor: Colors.black.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerHigh : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ctaBg,
          foregroundColor: ctaFg,
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      // The FAB carries the brand blue — the positive "add" action.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: blue,
        foregroundColor: Colors.white,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? scheme.surfaceContainerHighest : ink,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  /// A disciplined type scale: heavy, tightly-tracked display headlines against
  /// a calm body — the black-on-cream contrast that defines the direction. The
  /// wide-tracked uppercase micro-labels are set inline at the call sites.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    final onSurface = scheme.onSurface;
    return base.copyWith(
      headlineLarge: base.headlineLarge?.copyWith(
        color: onSurface, fontWeight: FontWeight.w900, letterSpacing: -0.6),
      headlineMedium: base.headlineMedium?.copyWith(
        color: onSurface, fontWeight: FontWeight.w800, letterSpacing: -0.5),
      headlineSmall: base.headlineSmall?.copyWith(
        color: onSurface, fontWeight: FontWeight.w800, letterSpacing: -0.3),
      titleLarge: base.titleLarge?.copyWith(
        color: onSurface, fontWeight: FontWeight.w800, letterSpacing: -0.3),
      titleMedium: base.titleMedium?.copyWith(
        color: onSurface, fontWeight: FontWeight.w700),
      bodyLarge: base.bodyLarge?.copyWith(color: onSurface, height: 1.5),
      bodyMedium: base.bodyMedium?.copyWith(color: onSurface, height: 1.5),
    );
  }
}
