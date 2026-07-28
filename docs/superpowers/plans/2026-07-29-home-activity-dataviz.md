# Home "Your Activity" Data-Viz Block — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Your activity" block to the patient Home tab — a weekly recap stat card (sparklines + week-over-week change) and a consistency heatmap — both computed client-side from the readings already loaded.

**Architecture:** One pure Dart module reduces the raw readings list into two summaries (per-day counts, per-metric weekly recaps) with no Flutter dependencies of its own beyond the `ReadingType` metadata. Two stateless/stateful card widgets render those summaries. The Home tab inserts both cards inside a `FutureBuilder` on the existing `_readings` future. No new API calls, no backend changes.

**Tech Stack:** Flutter / Dart, `flutter_test` for unit + widget tests, existing `Sparkline` (`trend_chart.dart`), `ReadingType`/`readingTypes` (`readings.dart`), `MedThruTheme` (`theme.dart`).

## Global Constraints

- No new backend endpoints or network calls; consume the existing `_readings` future only.
- Reading map shape: `reading_type` (String), `value` (num), `taken_at` (ISO String, `DateTime.parse`-able). `getReadings` returns readings **newest-first**.
- Reuse the existing `Sparkline` widget — do not write a new one.
- Neutral tone: never good/bad framing on change direction. In/out-of-range coloring only via `ReadingType.withinTypical` (`MedThruTheme.iconGreen` within, `MedThruTheme.danger` out).
- No streaks, no streak counters, no mascot.
- Metrics considered: all `ReadingCategory.vital` types plus `weight`; **exclude `height`**.
- Heatmap window: 16 weeks, Monday-first weeks (matches `appointment_calendar.dart`).
- Placement: a "Your activity" block inserted in `_HomeTab.build` immediately before the `_VitalsSnapshot` `FutureBuilder` (currently `patient_screen.dart:635`).

---

### Task 1: Per-day counts + heat levels (pure)

**Files:**
- Create: `app/lib/activity_summary.dart`
- Test: `app/test/activity_summary_test.dart`

**Interfaces:**
- Consumes: `ReadingType`/`readingTypes` from `readings.dart` (Task 2 only).
- Produces:
  - `Map<DateTime,int> dailyReadingCounts(List<Map<String,dynamic>> readings)` — count of readings per local calendar day (midnight-keyed); readings with missing/unparseable `taken_at` are skipped.
  - `int heatLevel(int count)` — 0 for ≤0, 1 for 1, 2 for 2–3, 3 for 4+.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/activity_summary_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/activity_summary_test.dart`
Expected: FAIL — `activity_summary.dart` / `dailyReadingCounts` not defined.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/activity_summary.dart
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
```

Note: the unused `readings.dart` import is intentional — Task 2 adds code that uses it. If the linter complains before Task 2, add `// ignore: unused_import` temporarily and remove it in Task 2.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/activity_summary_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/activity_summary.dart app/test/activity_summary_test.dart
git commit -m "Add per-day reading counts and heat levels for activity block"
```

---

### Task 2: Weekly recap reducer (pure)

**Files:**
- Modify: `app/lib/activity_summary.dart`
- Test: `app/test/activity_summary_test.dart` (add a group)

**Interfaces:**
- Consumes: `dailyReadingCounts`/`heatLevel` (same file); `ReadingType`, `readingTypes` from `readings.dart`.
- Produces:
  - `class MetricRecap` with final fields: `ReadingType spec`, `double latest`, `bool? within`, `double? changePct`, `double? changeAbs`, `List<double> series`.
  - `List<MetricRecap> weeklyRecap(List<Map<String,dynamic>> readings, {DateTime? now, int max = 3})` — up to `max` metrics ranked by number of readings in the last 14 days (desc), each with week-over-week change. Excludes `height` and unknown/non-numeric types. A metric needs ≥2 readings in the last 14 days to appear. `changePct`/`changeAbs` are null when the prior 7-day window (days 7–14 back) has no data. Empty list when nothing qualifies.

- [ ] **Step 1: Write the failing test**

```dart
// append inside main() in app/test/activity_summary_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/activity_summary_test.dart`
Expected: FAIL — `weeklyRecap` / `MetricRecap` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `app/lib/activity_summary.dart` (and remove any temporary `ignore: unused_import` added in Task 1):

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/activity_summary_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add app/lib/activity_summary.dart app/test/activity_summary_test.dart
git commit -m "Add weekly recap reducer for activity block"
```

---

### Task 3: Consistency heatmap card

**Files:**
- Create: `app/lib/screens/patient/consistency_heatmap.dart`
- Test: `app/test/consistency_heatmap_test.dart`

**Interfaces:**
- Consumes: `dailyReadingCounts`, `heatLevel` from `activity_summary.dart`; `MedThruTheme`.
- Produces: `class ConsistencyHeatmapCard extends StatefulWidget` with `const ConsistencyHeatmapCard({super.key, required List<Map<String,dynamic>> readings, int weeks = 16})`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/consistency_heatmap_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/screens/patient/consistency_heatmap.dart';
import 'package:medthru_app/theme.dart';

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> readings) {
  return tester.pumpWidget(MaterialApp(
    theme: MedThruTheme.light(),
    home: Scaffold(body: ConsistencyHeatmapCard(readings: readings)),
  ));
}

void main() {
  testWidgets('shows the empty caption when there is no history', (tester) async {
    await _pump(tester, const []);
    expect(find.text('Your logging history will fill in here'), findsOneWidget);
  });

  testWidgets('renders the section heading with readings present', (tester) async {
    await _pump(tester, [
      {
        'reading_type': 'blood_sugar',
        'value': 5.4,
        'taken_at': DateTime.now().toIso8601String(),
      },
    ]);
    expect(find.text('LOGGING ACTIVITY'), findsOneWidget);
    expect(find.text('Your logging history will fill in here'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/consistency_heatmap_test.dart`
Expected: FAIL — `consistency_heatmap.dart` not found.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/screens/patient/consistency_heatmap.dart
import 'package:flutter/material.dart';
import '../../activity_summary.dart';
import '../../theme.dart';

/// A GitHub-style contribution grid of daily logging activity over the last
/// [weeks] weeks. Read-only, low-pressure: no streaks, just the grid filling
/// in. Tapping a populated day reveals its count below the grid.
class ConsistencyHeatmapCard extends StatefulWidget {
  const ConsistencyHeatmapCard({
    super.key,
    required this.readings,
    this.weeks = 16,
  });

  final List<Map<String, dynamic>> readings;
  final int weeks;

  @override
  State<ConsistencyHeatmapCard> createState() => _ConsistencyHeatmapCardState();
}

class _ConsistencyHeatmapCardState extends State<ConsistencyHeatmapCard> {
  DateTime? _selected;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = dailyReadingCounts(widget.readings);
    final hasHistory = counts.isNotEmpty;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Monday of the current week, then back to the first shown week.
    final mondayThisWeek = today.subtract(Duration(days: today.weekday - 1));
    final start =
        mondayThisWeek.subtract(Duration(days: (widget.weeks - 1) * 7));

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LOGGING ACTIVITY',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _grid(scheme, start, today, counts),
          const SizedBox(height: 8),
          if (!hasHistory)
            Text(
              'Your logging history will fill in here',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            )
          else
            _footer(scheme, counts),
        ],
      ),
    );
  }

  Widget _grid(ColorScheme scheme, DateTime start, DateTime today,
      Map<DateTime, int> counts) {
    final columns = <Widget>[];
    for (var w = 0; w < widget.weeks; w++) {
      final cells = <Widget>[];
      for (var d = 0; d < 7; d++) {
        final date = start.add(Duration(days: w * 7 + d));
        final future = date.isAfter(today);
        final count = counts[date] ?? 0;
        cells.add(_cell(scheme, date, count, future));
      }
      columns.add(Column(children: cells));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true, // newest week visible first
      child: Row(children: columns),
    );
  }

  Widget _cell(ColorScheme scheme, DateTime date, int count, bool future) {
    final level = heatLevel(count);
    final selected = _selected != null &&
        _selected!.year == date.year &&
        _selected!.month == date.month &&
        _selected!.day == date.day;
    final color = future
        ? Colors.transparent
        : level == 0
            ? scheme.surfaceContainerHighest
            : MedThruTheme.blue.withValues(alpha: [0.0, 0.35, 0.65, 1.0][level]);
    return GestureDetector(
      onTap: count == 0
          ? null
          : () => setState(() => _selected = selected ? null : date),
      child: Container(
        width: 13,
        height: 13,
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: selected
              ? Border.all(color: scheme.onSurface, width: 1.2)
              : null,
        ),
      ),
    );
  }

  Widget _footer(ColorScheme scheme, Map<DateTime, int> counts) {
    if (_selected != null) {
      final c = counts[_selected!] ?? 0;
      return Text(
        '${_selected!.day} ${_months[_selected!.month - 1]} — '
        '$c ${c == 1 ? 'reading' : 'readings'}',
        style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
      );
    }
    return Row(
      children: [
        Text('Less',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        const SizedBox(width: 6),
        for (final a in const [0.0, 0.35, 0.65, 1.0])
          Container(
            width: 11,
            height: 11,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: a == 0.0
                  ? scheme.surfaceContainerHighest
                  : MedThruTheme.blue.withValues(alpha: a),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 6),
        Text('More',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/consistency_heatmap_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/patient/consistency_heatmap.dart app/test/consistency_heatmap_test.dart
git commit -m "Add consistency heatmap card"
```

---

### Task 4: Weekly recap stat card

**Files:**
- Create: `app/lib/screens/patient/activity_recap.dart`
- Test: `app/test/activity_recap_test.dart`

**Interfaces:**
- Consumes: `weeklyRecap`, `MetricRecap` from `activity_summary.dart`; `Sparkline` from `trend_chart.dart`; `ReadingType` from `readings.dart`; `MedThruTheme`.
- Produces: `class ActivityRecapCard extends StatelessWidget` with `const ActivityRecapCard({super.key, required List<Map<String,dynamic>> readings})`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/activity_recap_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/screens/patient/activity_recap.dart';
import 'package:medthru_app/theme.dart';

Map<String, dynamic> r(String type, num value, String takenAt) =>
    {'reading_type': type, 'value': value, 'taken_at': takenAt};

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> readings) {
  return tester.pumpWidget(MaterialApp(
    theme: MedThruTheme.light(),
    home: Scaffold(body: ActivityRecapCard(readings: readings)),
  ));
}

void main() {
  testWidgets('shows the unlock line when there is too little data',
      (tester) async {
    await _pump(tester, const []);
    expect(find.textContaining('unlock your weekly recap'), findsOneWidget);
  });

  testWidgets('renders a tile per qualifying metric', (tester) async {
    final base = DateTime.now();
    String at(int daysAgo) =>
        base.subtract(Duration(days: daysAgo)).toIso8601String();
    await _pump(tester, [
      r('blood_sugar', 5.4, at(1)),
      r('blood_sugar', 5.6, at(2)),
      r('blood_sugar', 6.0, at(9)),
    ]);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('Blood sugar'), findsOneWidget);
    expect(find.textContaining('unlock your weekly recap'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/activity_recap_test.dart`
Expected: FAIL — `activity_recap.dart` not found.

- [ ] **Step 3: Write minimal implementation**

```dart
// app/lib/screens/patient/activity_recap.dart
import 'package:flutter/material.dart';
import '../../activity_summary.dart';
import '../../theme.dart';
import '../../trend_chart.dart' show Sparkline;

/// A weekly recap of the patient's most active metrics — value, week-over-week
/// change, and a sparkline each. Complements (does not duplicate) the vital
/// signs snapshot: this one is about *change over the week*, not latest value.
/// Tone is neutral: a direction is never framed as good or bad.
class ActivityRecapCard extends StatelessWidget {
  const ActivityRecapCard({super.key, required this.readings});

  final List<Map<String, dynamic>> readings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recaps = weeklyRecap(readings);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'THIS WEEK',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (recaps.isEmpty)
            Text(
              'Log a few more readings to unlock your weekly recap.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [for (final m in recaps) _RecapTile(recap: m)],
            ),
        ],
      ),
    );
  }
}

class _RecapTile extends StatelessWidget {
  const _RecapTile({required this.recap});
  final MetricRecap recap;

  @override
  Widget build(BuildContext context) {
    final spec = recap.spec;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minWidth: 104),
      decoration: BoxDecoration(
        color: spec.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 13, color: spec.color(context)),
              const SizedBox(width: 4),
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: spec.color(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${spec.format(recap.latest)} ${spec.unit}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          _changeLabel(scheme),
          if (recap.series.length >= 2) ...[
            const SizedBox(height: 6),
            Sparkline(
              values: recap.series,
              color: spec.color(context),
              low: spec.low,
              high: spec.high,
              width: 96,
              height: 24,
            ),
          ],
        ],
      ),
    );
  }

  Widget _changeLabel(ColorScheme scheme) {
    final pct = recap.changePct;
    if (pct == null) {
      return Text(
        'no prior week',
        style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
      );
    }
    // Neutral: the arrow shows direction only, never colored good/bad.
    final flat = pct.abs() < 0.5;
    final arrow = flat ? '→' : (pct > 0 ? '↑' : '↓');
    final weight = recap.spec.key == 'weight';
    final magnitude = weight
        ? '${recap.changeAbs!.abs().toStringAsFixed(1)} ${recap.spec.unit}'
        : '${pct.abs().toStringAsFixed(0)}%';
    return Text(
      flat ? 'about the same' : '$arrow $magnitude vs last week',
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/activity_recap_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/patient/activity_recap.dart app/test/activity_recap_test.dart
git commit -m "Add weekly recap stat card"
```

---

### Task 5: Wire the "Your activity" block into Home

**Files:**
- Modify: `app/lib/screens/patient/patient_screen.dart` (imports near top; `_HomeTab.build` list around line 635)

**Interfaces:**
- Consumes: `ActivityRecapCard` (Task 4), `ConsistencyHeatmapCard` (Task 3), the existing `_readings` future and its `FutureBuilder` pattern.
- Produces: no new exported symbols.

- [ ] **Step 1: Add imports**

At the top of `patient_screen.dart`, alongside the other `screens/patient/` imports (e.g. near the `appointment_calendar.dart` import), add:

```dart
import 'activity_recap.dart';
import 'consistency_heatmap.dart';
```

- [ ] **Step 2: Insert the block before the vitals snapshot**

Find the `_VitalsSnapshot` `FutureBuilder` in `_HomeTab.build` (the `FutureBuilder<List<Map<String, dynamic>>>(future: _readings, ...)` that returns `_VitalsSnapshot`, currently starting at line 635). Immediately **before** it, insert:

```dart
        // "Your activity": weekly recap + consistency heatmap, both derived
        // from the same readings future as the vitals snapshot below.
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _readings,
          builder: (context, snap) {
            final readings = snap.data;
            if (readings == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                children: [
                  ActivityRecapCard(readings: readings),
                  const SizedBox(height: 12),
                  ConsistencyHeatmapCard(readings: readings),
                ],
              ),
            );
          },
        ),

```

- [ ] **Step 3: Analyze**

Run: `cd app && flutter analyze lib/screens/patient/patient_screen.dart lib/screens/patient/activity_recap.dart lib/screens/patient/consistency_heatmap.dart lib/activity_summary.dart`
Expected: No issues found.

- [ ] **Step 4: Run the full test suite**

Run: `cd app && flutter test`
Expected: PASS — new tests plus the existing suite (no regressions).

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/patient/patient_screen.dart
git commit -m "Show Your activity block on patient Home tab"
```

---

## Self-Review

**Spec coverage:**
- Consistency heatmap (12–16 wk, intensity by count, tap-to-reveal, legend, empty state) → Task 3. ✓ (fixed at 16 weeks per Global Constraints.)
- Weekly recap stat card (top-3 by activity, value + WoW change + sparkline, neutral tone, in/out-of-range color, insufficient-data fallback) → Tasks 2 + 4. ✓
- Data from existing `_readings`, client-side, no backend → Task 5 reuses the `_readings` future. ✓
- Placement near top of Home, above vitals snapshot → Task 5 inserts before the `_VitalsSnapshot` FutureBuilder. ✓
- Pure, testable reducer separate from widgets → Task 1 + 2 (`activity_summary.dart`). ✓
- Reuse `Sparkline`, `ReadingType`, tap-reveal/Monday-week patterns → Tasks 3 + 4. ✓
- "Moments" highlight was marked optional/deferrable in the spec → intentionally omitted from the first cut; not a gap.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — all code is inline. ✓

**Type consistency:** `MetricRecap` fields (`spec`, `latest`, `within`, `changePct`, `changeAbs`, `series`) defined in Task 2 are consumed unchanged in Task 4. `weeklyRecap`/`dailyReadingCounts`/`heatLevel` signatures match across tasks. `ConsistencyHeatmapCard`/`ActivityRecapCard` constructors match their Task 5 call sites. `Sparkline` params match the existing widget in `trend_chart.dart`. ✓
