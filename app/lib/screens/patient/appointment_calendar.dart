import 'package:flutter/material.dart';
import '../../activity_summary.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart' show formatAppointmentTime, StatusPill;

/// A month-at-a-glance calendar on the patient Home tab. Each day is shaded by
/// how many readings were logged that day (a green heatmap) and marked with a
/// dot when it carries an appointment; tapping a day with an appointment lists
/// what's on it. Read-only: booking, cancelling and reminders all live on the
/// full Appointments screen, reached with [onOpenAll] — this is a glanceable
/// overview, not a replacement for it.
class AppointmentCalendarCard extends StatefulWidget {
  const AppointmentCalendarCard({
    super.key,
    required this.cardToken,
    required this.readings,
    required this.onOpenAll,
    this.today,
  });

  final String cardToken;

  /// The day treated as "today": which month opens, and which cell gets the
  /// today ring. Defaults to the real clock; tests pin it so the rendered
  /// month — and the golden of it — doesn't change with the calendar.
  final DateTime? today;

  /// The patient's readings, used to shade each day by logging activity. The
  /// card computes per-day counts itself; passing an empty list just leaves the
  /// grid unshaded.
  final List<Map<String, dynamic>> readings;

  /// Opens the full Appointments screen and completes when it's popped, so the
  /// calendar can refresh against any booking or cancellation made there.
  final Future<void> Function() onOpenAll;

  @override
  State<AppointmentCalendarCard> createState() =>
      _AppointmentCalendarCardState();
}

class _AppointmentCalendarCardState extends State<AppointmentCalendarCard> {
  late Future<List<Map<String, dynamic>>> _future;

  /// The first day of the month currently on screen.
  late DateTime _month;

  /// The day whose appointments are listed below the grid, if any.
  DateTime? _selected;

  /// Appointments grouped by their calendar day (year-month-day at midnight).
  Map<DateTime, List<Map<String, dynamic>>> _byDay = {};

  /// Readings logged per calendar day, recomputed from [widget.readings] each
  /// build — it drives the green day shading.
  Map<DateTime, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    final now = widget.today ?? DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getMyAppointments(widget.cardToken);
    _future
        .then((appts) {
          if (!mounted) return;
          setState(() => _byDay = _group(appts));
        })
        .catchError((_) {
          // A failed fetch just leaves an empty calendar; the full Appointments
          // screen surfaces the actual error when the patient opens it.
        });
  }

  static Map<DateTime, List<Map<String, dynamic>>> _group(
    List<Map<String, dynamic>> appts,
  ) {
    final map = <DateTime, List<Map<String, dynamic>>>{};
    for (final a in appts) {
      final raw = a['starts_at'] as String?;
      if (raw == null) continue;
      final dt = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
      if (dt == null) continue;
      final key = DateTime(dt.year, dt.month, dt.day);
      (map[key] ??= []).add(a);
    }
    return map;
  }

  /// Open the full Appointments screen, then reload — a booking or cancellation
  /// made over there would otherwise leave this glance card stale.
  Future<void> _openAll() async {
    await widget.onOpenAll();
    if (mounted) setState(_load);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = null;
    });
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = widget.today ?? DateTime.now();
    _counts = dailyReadingCounts(widget.readings);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: MedThruTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(scheme),
          _consistencyLine(scheme),
          const SizedBox(height: 12),
          _weekdayRow(scheme),
          const SizedBox(height: 4),
          _grid(scheme, today),
          _legend(scheme),
          _details(scheme),
        ],
      ),
    );
  }

  // The lime logging ramp. Lime is the brand's "positive figure" accent, so it
  // reads as "you showed up" — and, unlike green, it can't be mistaken for the
  // within-range success colour used on vitals. Dark ink text stays legible on
  // it at every step.
  static const _limeRamp = [0.0, 0.28, 0.55, 0.90];

  /// Graded lime fill for a day's logging intensity; null for an unlogged day.
  Color? _heatColor(DateTime date) {
    final level = heatLevel(_counts[date] ?? 0);
    if (level == 0) return null;
    return MedThruTheme.lime.withValues(alpha: _limeRamp[level]);
  }

  /// States the month's logging record in words, so the grid reads as a
  /// consistency record at a glance rather than a bare calendar.
  Widget _consistencyLine(ColorScheme scheme) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    var logged = 0;
    for (var d = 1; d <= daysInMonth; d++) {
      if ((_counts[DateTime(_month.year, _month.month, d)] ?? 0) > 0) logged++;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$logged',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            TextSpan(
              text: ' of $daysInMonth days logged',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 12.5),
      ),
    );
  }

  /// A compact key: the lime logging scale, and what the appointment dot means.
  Widget _legend(ColorScheme scheme) {
    final labelStyle = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    Widget swatch(double alpha) => Container(
      width: 11,
      height: 11,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: alpha == 0.0
            ? scheme.surfaceContainerHighest
            : MedThruTheme.lime.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Logged', style: labelStyle),
              const SizedBox(width: 6),
              for (final a in _limeRamp) swatch(a),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: MedThruTheme.blue,
                ),
              ),
              const SizedBox(width: 5),
              Text('appointment', style: labelStyle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Row(
      children: [
        // Flexible so a long month label ellipsizes instead of overflowing the
        // row on narrow layouts, rather than forcing the controls off-edge.
        Flexible(
          // Month heavy, year light — a small deliberate pairing rather than one
          // flat label.
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: _months[_month.month - 1],
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: ' ${_month.year}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5),
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Previous month',
          icon: const Icon(Icons.chevron_left, size: 20),
          visualDensity: VisualDensity.compact,
          onPressed: () => _shiftMonth(-1),
        ),
        IconButton(
          tooltip: 'Next month',
          icon: const Icon(Icons.chevron_right, size: 20),
          visualDensity: VisualDensity.compact,
          onPressed: () => _shiftMonth(1),
        ),
        TextButton(
          onPressed: _openAll,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('View all'),
        ),
      ],
    );
  }

  Widget _weekdayRow(ColorScheme scheme) {
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Row(
      children: [
        for (final l in labels)
          Expanded(
            child: Center(
              child: Text(
                l,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _grid(ColorScheme scheme, DateTime today) {
    // Monday-first: how many blank cells precede the 1st.
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday; // 1..7
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = firstWeekday - 1;
    final totalCells = ((leading + daysInMonth) / 7).ceil() * 7;

    final rows = <Widget>[];
    for (var i = 0; i < totalCells; i += 7) {
      final cells = <Widget>[];
      for (var j = 0; j < 7; j++) {
        final cellIndex = i + j;
        final dayNum = cellIndex - leading + 1;
        if (dayNum < 1 || dayNum > daysInMonth) {
          cells.add(const Expanded(child: SizedBox(height: 40)));
        } else {
          final date = DateTime(_month.year, _month.month, dayNum);
          cells.add(Expanded(child: _dayCell(scheme, date, today)));
        }
      }
      rows.add(Row(children: cells));
    }
    return Column(children: rows);
  }

  Widget _dayCell(ColorScheme scheme, DateTime date, DateTime today) {
    final appts = _byDay[date] ?? const [];
    final isToday = _sameDay(date, today);
    final isSelected = _selected != null && _sameDay(date, _selected!);
    final hasAppts = appts.isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: hasAppts
          ? () => setState(() => _selected = isSelected ? null : date)
          : null,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          // Background carries the logging heat; today and the selected day are
          // drawn as a blue ring so the shading still shows through.
          color: _heatColor(date),
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(color: MedThruTheme.blue, width: 2)
              : isToday
              ? Border.all(color: MedThruTheme.blue, width: 1.4)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: (isToday || isSelected)
                    ? FontWeight.w800
                    : FontWeight.w500,
                color: isToday ? MedThruTheme.blue : scheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 5,
              child: hasAppts
                  ? Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _dotColor(appts),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Confirmed appointments read as "locked in" (blue); anything still just
  /// requested is amber; a day with only past/closed ones is muted. An
  /// appointment with a reschedule pending still holds this slot, so it reads
  /// as locked in too — the day is genuinely spoken for until someone responds.
  Color _dotColor(List<Map<String, dynamic>> appts) {
    if (appts.any((a) =>
        a['status'] == 'confirmed' || a['status'] == 'reschedule_requested')) {
      return MedThruTheme.blue;
    }
    if (appts.any((a) => a['status'] == 'requested')) {
      return MedThruTheme.amber;
    }
    // Only past/closed appointments left (completed, cancelled): mute the dot
    // so it doesn't compete with days that still have something coming up.
    return MedThruTheme.muted;
  }

  Widget _details(ColorScheme scheme) {
    // With a day selected, list that day. Otherwise show the next upcoming
    // appointment so the card is never just a bare grid.
    final List<Map<String, dynamic>> items;
    final String heading;
    if (_selected != null) {
      items = List.of(_byDay[_selected!] ?? const [])
        ..sort(
          (a, b) =>
              (a['starts_at'] as String).compareTo(b['starts_at'] as String),
        );
      heading = _dayLabel(_selected!);
    } else {
      final next = _nextUpcoming();
      items = next == null ? const [] : [next];
      heading = next == null ? '' : 'NEXT UP';
    }

    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          'No upcoming appointments. Tap “View all” to book one.',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Divider(color: scheme.outlineVariant, height: 1),
        const SizedBox(height: 10),
        Text(
          heading.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final a in items) _miniRow(scheme, a),
      ],
    );
  }

  Widget _miniRow(ColorScheme scheme, Map<String, dynamic> a) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _openAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatAppointmentTime(a['starts_at'] as String),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    a['clinic_name'] as String? ?? '',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            StatusPill(status: a['status'] as String),
          ],
        ),
      ),
    );
  }

  /// The soonest appointment at or after now, ignoring closed ones.
  Map<String, dynamic>? _nextUpcoming() {
    final now = widget.today ?? DateTime.now();
    Map<String, dynamic>? best;
    DateTime? bestAt;
    for (final list in _byDay.values) {
      for (final a in list) {
        final status = a['status'];
        if (status != 'confirmed' &&
            status != 'requested' &&
            status != 'reschedule_requested') {
          continue;
        }
        final dt = DateTime.tryParse(
          (a['starts_at'] as String).replaceFirst(' ', 'T'),
        );
        if (dt == null || dt.isBefore(now)) continue;
        if (bestAt == null || dt.isBefore(bestAt)) {
          bestAt = dt;
          best = a;
        }
      }
    }
    return best;
  }

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _dayLabel(DateTime d) =>
      '${_months[d.month - 1].substring(0, 3)} ${d.day}, ${d.year}';
}
