// Pure logic tests for aggregateDaily: the default that collapses several
// same-day readings (e.g. vitals a patient self-checks a few times a day)
// into one daily-average point plus a low/high band, so a doctor sees a
// trend instead of a jagged raw line.
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/trend_chart.dart';

TrendPoint _p(DateTime t, double v) => (t: t, v: v);

void main() {
  test('one reading per day passes through unchanged, band mirrors the value', () {
    final points = [
      _p(DateTime(2026, 1, 1), 5.0),
      _p(DateTime(2026, 1, 2), 5.4),
    ];
    final agg = aggregateDaily(points);

    expect(agg.points.map((p) => p.v), [5.0, 5.4]);
    expect(agg.bands, [
      (lo: 5.0, hi: 5.0, count: 1),
      (lo: 5.4, hi: 5.4, count: 1),
    ]);
  });

  test('same-day readings collapse to one point: mean value, min/max band', () {
    final points = [
      _p(DateTime(2026, 1, 1, 8), 118.0),
      _p(DateTime(2026, 1, 1, 13), 130.0),
      _p(DateTime(2026, 1, 1, 20), 122.0),
      _p(DateTime(2026, 1, 2, 9), 125.0),
    ];
    final agg = aggregateDaily(points);

    expect(agg.points.length, 2);
    expect(agg.points[0].t, DateTime(2026, 1, 1));
    expect(agg.points[0].v, closeTo((118.0 + 130.0 + 122.0) / 3, 1e-9));
    expect(agg.bands[0], (lo: 118.0, hi: 130.0, count: 3));
    expect(agg.points[1].v, 125.0);
    expect(agg.bands[1], (lo: 125.0, hi: 125.0, count: 1));
  });

  test('out-of-order input is grouped and returned in day order', () {
    final points = [
      _p(DateTime(2026, 3, 5, 21), 70.0),
      _p(DateTime(2026, 3, 4, 7), 69.0),
      _p(DateTime(2026, 3, 5, 7), 71.0),
    ];
    final agg = aggregateDaily(points);

    expect(agg.points.map((p) => p.t), [DateTime(2026, 3, 4), DateTime(2026, 3, 5)]);
    expect(agg.bands[1], (lo: 70.0, hi: 71.0, count: 2));
  });

  test('empty input returns empty output', () {
    final agg = aggregateDaily(const []);
    expect(agg.points, isEmpty);
    expect(agg.bands, isEmpty);
  });
}
