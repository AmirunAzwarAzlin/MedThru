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

  group('weeklyRecap', () {
    final now = DateTime(2026, 7, 29, 12); // reference "today"

    test('empty readings produce no recaps', () {
      expect(weeklyRecap([], now: now), isEmpty);
    });

    test('needs at least 2 readings in the last 14 days', () {
      final recaps = weeklyRecap([
        r('blood_sugar', 5.4, '2026-07-28 08:00'),
      ], now: now);
      expect(recaps, isEmpty);
    });

    test('computes week-over-week percent change and latest', () {
      final recaps = weeklyRecap([
        // last week (days 7-14 back): mean 6.0
        r('blood_sugar', 6.0, '2026-07-18 08:00'),
        r('blood_sugar', 6.0, '2026-07-19 08:00'),
        // this week (last 7 days): mean 5.4, latest 5.4
        r('blood_sugar', 5.4, '2026-07-27 08:00'),
        r('blood_sugar', 5.4, '2026-07-28 08:00'),
      ], now: now);
      expect(recaps, hasLength(1));
      final m = recaps.single;
      expect(m.spec.key, 'blood_sugar');
      expect(m.latest, 5.4);
      expect(m.changePct, closeTo(-10.0, 0.001));
      expect(m.changeAbs, closeTo(-0.6, 0.001));
      expect(m.series, [6.0, 6.0, 5.4, 5.4]);
    });

    test('change is null when there is no prior-week data', () {
      final recaps = weeklyRecap([
        r('weight', 71, '2026-07-27 08:00'),
        r('weight', 70, '2026-07-28 08:00'),
      ], now: now);
      expect(recaps.single.changePct, isNull);
      expect(recaps.single.changeAbs, isNull);
    });

    test('excludes height and unknown types', () {
      final recaps = weeklyRecap([
        r('height', 170, '2026-07-27 08:00'),
        r('height', 170, '2026-07-28 08:00'),
        r('made_up', 1, '2026-07-27 08:00'),
        r('made_up', 1, '2026-07-28 08:00'),
      ], now: now);
      expect(recaps, isEmpty);
    });

    test('ranks by recent activity and caps at max', () {
      final readings = <Map<String, dynamic>>[
        // blood_sugar: 4 readings in last 14 days
        r('blood_sugar', 5, '2026-07-26 08:00'),
        r('blood_sugar', 5, '2026-07-27 08:00'),
        r('blood_sugar', 5, '2026-07-28 08:00'),
        r('blood_sugar', 5, '2026-07-29 08:00'),
        // weight: 2 readings
        r('weight', 70, '2026-07-27 08:00'),
        r('weight', 70, '2026-07-28 08:00'),
        // heart_rate: 3 readings
        r('heart_rate', 72, '2026-07-26 08:00'),
        r('heart_rate', 72, '2026-07-27 08:00'),
        r('heart_rate', 72, '2026-07-28 08:00'),
      ];
      final recaps = weeklyRecap(readings, now: now, max: 2);
      expect(recaps.map((m) => m.spec.key).toList(),
          ['blood_sugar', 'heart_rate']);
    });
  });
}
