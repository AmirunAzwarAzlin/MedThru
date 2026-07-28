import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/activity_summary.dart';

Map<String, dynamic> r(String type, num value, String takenAt) =>
    {'reading_type': type, 'value': value, 'taken_at': takenAt};

void main() {
  group('dailyReadingCounts', () {
    test('groups readings by calendar day and ignores time of day', () {
      final counts = dailyReadingCounts([
        r('blood_sugar', 5.4, '2026-07-20 08:00'),
        r('blood_sugar', 6.1, '2026-07-20 21:30'),
        r('weight', 70, '2026-07-21 09:00'),
      ]);
      expect(counts[DateTime(2026, 7, 20)], 2);
      expect(counts[DateTime(2026, 7, 21)], 1);
    });

    test('skips readings with missing or unparseable taken_at', () {
      final counts = dailyReadingCounts([
        r('blood_sugar', 5.4, 'not-a-date'),
        {'reading_type': 'weight', 'value': 70},
      ]);
      expect(counts, isEmpty);
    });
  });

  group('heatLevel', () {
    test('buckets counts into 0..3', () {
      expect(heatLevel(0), 0);
      expect(heatLevel(1), 1);
      expect(heatLevel(2), 2);
      expect(heatLevel(3), 2);
      expect(heatLevel(4), 3);
      expect(heatLevel(9), 3);
    });
  });
}
