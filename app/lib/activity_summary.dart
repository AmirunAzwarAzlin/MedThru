import 'readings.dart';

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

DateTime? _readingDay(Map<String, dynamic> r) {
  final raw = r['taken_at'];
  if (raw is! String) return null;
  final t = DateTime.tryParse(raw);
  return t == null ? null : _dayOf(t);
}

/// Number of readings logged on each local calendar day (keyed at midnight).
Map<DateTime, int> dailyReadingCounts(List<Map<String, dynamic>> readings) {
  final counts = <DateTime, int>{};
  for (final r in readings) {
    final day = _readingDay(r);
    if (day == null) continue;
    counts[day] = (counts[day] ?? 0) + 1;
  }
  return counts;
}

/// Maps a day's reading count to a 0..3 intensity level for the heatmap.
int heatLevel(int count) {
  if (count <= 0) return 0;
  if (count == 1) return 1;
  if (count <= 3) return 2;
  return 3;
}

/// One metric's week-over-week recap, derived from a patient's readings.
class MetricRecap {
  const MetricRecap({
    required this.spec,
    required this.latest,
    required this.within,
    required this.changePct,
    required this.changeAbs,
    required this.series,
  });

  final ReadingType spec;
  final double latest;
  final bool? within; // spec.withinTypical(latest); null when no range defined
  final double? changePct; // percent vs prior 7 days; null when no prior data
  final double? changeAbs; // absolute delta vs prior 7 days; null when no prior
  final List<double> series; // recent values oldest->newest, for the sparkline
}

double _mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

/// Up to [max] metrics ranked by readings logged in the last 14 days (desc),
/// each summarized week-over-week. Excludes `height` and unknown/non-numeric
/// readings. Empty when nothing has ≥2 readings in the window.
List<MetricRecap> weeklyRecap(
  List<Map<String, dynamic>> readings, {
  DateTime? now,
  int max = 3,
}) {
  final today = _dayOf(now ?? DateTime.now());
  final weekAgo = today.subtract(const Duration(days: 7));
  final twoWeeksAgo = today.subtract(const Duration(days: 14));

  final byType = <String, List<({DateTime day, double v})>>{};
  for (final row in readings) {
    final type = row['reading_type'];
    if (type is! String || type == 'height') continue;
    if (!readingTypes.containsKey(type)) continue;
    final value = row['value'];
    if (value is! num) continue;
    final day = _readingDay(row);
    if (day == null) continue;
    (byType[type] ??= []).add((day: day, v: value.toDouble()));
  }

  int recentCount(String key) =>
      byType[key]!.where((p) => !p.day.isBefore(twoWeeksAgo)).length;

  final recaps = <MetricRecap>[];
  for (final entry in byType.entries) {
    if (recentCount(entry.key) < 2) continue;
    final spec = readingTypes[entry.key]!;
    final pts = entry.value..sort((a, b) => a.day.compareTo(b.day));

    final thisWeek =
        pts.where((p) => !p.day.isBefore(weekAgo)).map((p) => p.v).toList();
    final lastWeek = pts
        .where((p) => !p.day.isBefore(twoWeeksAgo) && p.day.isBefore(weekAgo))
        .map((p) => p.v)
        .toList();

    double? changePct;
    double? changeAbs;
    if (thisWeek.isNotEmpty && lastWeek.isNotEmpty) {
      final tMean = _mean(thisWeek);
      final lMean = _mean(lastWeek);
      changeAbs = tMean - lMean;
      changePct = lMean == 0 ? null : (tMean - lMean) / lMean * 100;
    }

    final series = pts.map((p) => p.v).toList();
    recaps.add(MetricRecap(
      spec: spec,
      latest: pts.last.v,
      within: spec.withinTypical(pts.last.v),
      changePct: changePct,
      changeAbs: changeAbs,
      series: series.length > 12
          ? series.sublist(series.length - 12)
          : series,
    ));
  }

  recaps.sort(
      (a, b) => recentCount(b.spec.key).compareTo(recentCount(a.spec.key)));
  return recaps.length > max ? recaps.sublist(0, max) : recaps;
}
