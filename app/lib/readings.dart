import 'package:flutter/material.dart';
import 'theme.dart';

/// Metadata for the self-measured readings a patient can log.
///
/// `low`/`high` describe a *typical* reference range and are used only to
/// show a neutral in/out-of-range hint. They are not a diagnosis, and the UI
/// says so.
class ReadingType {
  const ReadingType({
    required this.key,
    required this.label,
    required this.unit,
    required this.icon,
    required this.color,
    required this.tile,
    required this.typical,
    this.low,
    this.high,
  });

  final String key;
  final String label;
  final String unit;
  final IconData icon;
  final Color color;
  final Color tile;
  final String typical;
  final double? low;
  final double? high;

  /// Uric acid is reported in whole numbers; the mmol/L values get a decimal.
  String format(num value) =>
      unit.startsWith('umol') ? value.toStringAsFixed(0) : value.toStringAsFixed(1);

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
    color: MedThruTheme.iconBlue,
    tile: MedThruTheme.tileBlue,
    typical: 'Typical fasting: 4.0 – 5.5 mmol/L',
    low: 4.0,
    high: 5.5,
  ),
  'cholesterol': ReadingType(
    key: 'cholesterol',
    label: 'Cholesterol',
    unit: 'mmol/L',
    icon: Icons.opacity_outlined,
    color: MedThruTheme.iconPurple,
    tile: MedThruTheme.tilePurple,
    typical: 'Typical total: below 5.2 mmol/L',
    high: 5.2,
  ),
  'uric_acid': ReadingType(
    key: 'uric_acid',
    label: 'Uric acid',
    unit: 'umol/L',
    icon: Icons.science_outlined,
    color: MedThruTheme.iconGreen,
    tile: MedThruTheme.tileGreen,
    typical: 'Typical: 200 – 430 umol/L',
    low: 200,
    high: 430,
  ),
};
