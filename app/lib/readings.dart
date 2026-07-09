import 'package:flutter/material.dart';

/// Metadata for the self-measured readings a patient can log.
///
/// `low`/`high` describe a *typical* reference range and are used only to
/// show a neutral in/out-of-range hint. They are not a diagnosis, and the UI
/// says so.
///
/// Colours are chosen per mode rather than flipped, and were checked with the
/// palette validator against each surface (white cards in light, #12294A in
/// dark): all inside the lightness band, above the chroma floor, above 3:1
/// contrast, worst-case colour-vision-deficiency separation dE ~24.
class ReadingType {
  const ReadingType({
    required this.key,
    required this.label,
    required this.unit,
    required this.icon,
    required this.colorLight,
    required this.colorDark,
    required this.tileLight,
    required this.tileDark,
    required this.typical,
    this.low,
    this.high,
  });

  final String key;
  final String label;
  final String unit;
  final IconData icon;
  final Color colorLight;
  final Color colorDark;
  final Color tileLight;
  final Color tileDark;
  final String typical;
  final double? low;
  final double? high;

  bool _isDark(BuildContext c) =>
      Theme.of(c).colorScheme.brightness == Brightness.dark;

  Color color(BuildContext c) => _isDark(c) ? colorDark : colorLight;
  Color tile(BuildContext c) => _isDark(c) ? tileDark : tileLight;

  /// Uric acid is reported in whole numbers; the mmol/L values get a decimal.
  String format(num value) => unit.startsWith('umol')
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  bool? withinTypical(num value) {
    if (low == null && high == null) return null;
    if (low != null && value < low!) return false;
    if (high != null && value > high!) return false;
    return true;
  }
}

const readingTypes = <String, ReadingType>{
  'blood_sugar': ReadingType(
    key: 'blood_sugar',
    label: 'Blood sugar',
    unit: 'mmol/L',
    icon: Icons.water_drop_outlined,
    colorLight: Color(0xFF1D7FD4),
    colorDark: Color(0xFF3D93E5),
    tileLight: Color(0xFFE3F0FD),
    tileDark: Color(0xFF163A5C),
    typical: 'Typical fasting: 4.0 – 5.5 mmol/L',
    low: 4.0,
    high: 5.5,
  ),
  'cholesterol': ReadingType(
    key: 'cholesterol',
    label: 'Cholesterol',
    unit: 'mmol/L',
    icon: Icons.opacity_outlined,
    colorLight: Color(0xFFB92D86),
    colorDark: Color(0xFFD0559E),
    tileLight: Color(0xFFFBE4F1),
    tileDark: Color(0xFF4A1739),
    typical: 'Typical total: below 5.2 mmol/L',
    high: 5.2,
  ),
  'uric_acid': ReadingType(
    key: 'uric_acid',
    label: 'Uric acid',
    unit: 'umol/L',
    icon: Icons.science_outlined,
    colorLight: Color(0xFF19A05B),
    colorDark: Color(0xFF28A968),
    tileLight: Color(0xFFDFF5E6),
    tileDark: Color(0xFF10402A),
    typical: 'Typical: 200 – 430 umol/L',
    low: 200,
    high: 430,
  ),
};
