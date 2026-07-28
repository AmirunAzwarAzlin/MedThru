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
