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
