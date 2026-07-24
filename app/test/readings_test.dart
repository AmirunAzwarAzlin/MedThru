// Pure logic tests for the reading-type metadata: formatting, typical-range
// checks and category assignment. No widgets, no network — fast regression
// coverage for the vitals/anthropometry split added to Health Records.
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/readings.dart';

void main() {
  test('all nine reading types are registered with the right category', () {
    const vitals = {
      'blood_sugar',
      'cholesterol',
      'uric_acid',
      'blood_pressure_systolic',
      'blood_pressure_diastolic',
      'heart_rate',
      'temperature',
    };
    const anthropometry = {'weight', 'height'};

    expect(readingTypes.keys.toSet(), vitals.union(anthropometry));
    for (final key in vitals) {
      expect(readingTypes[key]!.category, ReadingCategory.vital, reason: key);
    }
    for (final key in anthropometry) {
      expect(readingTypes[key]!.category, ReadingCategory.anthropometry, reason: key);
    }
  });

  test('uric acid formats as a whole number, others keep a decimal by default', () {
    expect(readingTypes['uric_acid']!.format(315), '315');
    expect(readingTypes['blood_sugar']!.format(5.2), '5.2');
    expect(readingTypes['weight']!.format(70.456), '70.5');
  });

  test('withinTypical respects the metric\'s own low/high bounds', () {
    final bloodSugar = readingTypes['blood_sugar']!; // 4.0 - 5.5
    expect(bloodSugar.withinTypical(4.8), isTrue);
    expect(bloodSugar.withinTypical(3.9), isFalse);
    expect(bloodSugar.withinTypical(5.6), isFalse);

    final cholesterol = readingTypes['cholesterol']!; // high only: 5.2
    expect(cholesterol.withinTypical(5.1), isTrue);
    expect(cholesterol.withinTypical(5.3), isFalse);
  });

  test('metrics with no reference range report withinTypical as null', () {
    expect(readingTypes['weight']!.withinTypical(70), isNull);
    expect(readingTypes['height']!.withinTypical(170), isNull);
  });
}
