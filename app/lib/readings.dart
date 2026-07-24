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
/// Which Health Records section a reading type belongs under.
enum ReadingCategory { vital, anthropometry }

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
    this.category = ReadingCategory.vital,
    this.decimals = 1,
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
  final ReadingCategory category;
  final int decimals;
  final double? low;
  final double? high;

  bool _isDark(BuildContext c) =>
      Theme.of(c).colorScheme.brightness == Brightness.dark;

  Color color(BuildContext c) => _isDark(c) ? colorDark : colorLight;
  Color tile(BuildContext c) => _isDark(c) ? tileDark : tileLight;

  String format(num value) => value.toStringAsFixed(decimals);

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
    decimals: 0,
    low: 200,
    high: 430,
  ),
  'blood_pressure_systolic': ReadingType(
    key: 'blood_pressure_systolic',
    label: 'Blood pressure (systolic)',
    unit: 'mmHg',
    icon: Icons.speed_outlined,
    colorLight: Color(0xFFD9720A),
    colorDark: Color(0xFFEE9A4B),
    tileLight: Color(0xFFFCEBDA),
    tileDark: Color(0xFF4A2F13),
    typical: 'Typical: 90 – 120 mmHg',
    decimals: 0,
    low: 90,
    high: 120,
  ),
  'blood_pressure_diastolic': ReadingType(
    key: 'blood_pressure_diastolic',
    label: 'Blood pressure (diastolic)',
    unit: 'mmHg',
    icon: Icons.speed_outlined,
    colorLight: Color(0xFFB45309),
    colorDark: Color(0xFFD98A3D),
    tileLight: Color(0xFFFBEEDD),
    tileDark: Color(0xFF3F2A0E),
    typical: 'Typical: 60 – 80 mmHg',
    decimals: 0,
    low: 60,
    high: 80,
  ),
  'heart_rate': ReadingType(
    key: 'heart_rate',
    label: 'Heart rate',
    unit: 'bpm',
    icon: Icons.favorite_outline,
    colorLight: Color(0xFFDB2777),
    colorDark: Color(0xFFEC5A9B),
    tileLight: Color(0xFFFCE4EF),
    tileDark: Color(0xFF4A1730),
    typical: 'Typical resting: 60 – 100 bpm',
    decimals: 0,
    low: 60,
    high: 100,
  ),
  'temperature': ReadingType(
    key: 'temperature',
    label: 'Temperature',
    unit: '°C',
    icon: Icons.thermostat_outlined,
    colorLight: Color(0xFFCA8A04),
    colorDark: Color(0xFFE0B23D),
    tileLight: Color(0xFFFBF3D9),
    tileDark: Color(0xFF453510),
    typical: 'Typical: 36.1 – 37.2 °C',
    low: 36.1,
    high: 37.2,
  ),
  'weight': ReadingType(
    key: 'weight',
    label: 'Weight',
    unit: 'kg',
    icon: Icons.monitor_weight_outlined,
    colorLight: Color(0xFF4F46E5),
    colorDark: Color(0xFF7A73EE),
    tileLight: Color(0xFFE8E7FC),
    tileDark: Color(0xFF241F52),
    typical: 'Varies by person — tracked over time, not a fixed range.',
    category: ReadingCategory.anthropometry,
  ),
  'height': ReadingType(
    key: 'height',
    label: 'Height',
    unit: 'cm',
    icon: Icons.straighten_outlined,
    colorLight: Color(0xFF0891B2),
    colorDark: Color(0xFF3BB6D1),
    tileLight: Color(0xFFDCF3F8),
    tileDark: Color(0xFF0E3540),
    typical: 'Tracked over time, not a fixed range.',
    decimals: 0,
    category: ReadingCategory.anthropometry,
  ),
};
