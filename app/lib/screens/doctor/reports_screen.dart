import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart';

/// Practice analytics for a doctor: appointment volume over recent weeks, the
/// most common diagnoses, and how appointments split by status. One call to
/// GET /api/doctor/reports; every figure is real.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getDoctorReports();
    _future.ignore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const _Scrollable(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Scrollable(
                child: CenteredMessage(
                  icon: Icons.error_outline,
                  title: 'Could not load reports',
                  subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
                  action: OutlinedButton.icon(
                    onPressed: () => setState(_load),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
              );
            }
            final data = snap.data ?? const {};
            final weeks = ((data['appointmentsByWeek'] as List?) ?? const [])
                .cast<Map<String, dynamic>>();
            final conditions = ((data['topConditions'] as List?) ?? const [])
                .cast<Map<String, dynamic>>();
            final statuses = ((data['statusBreakdown'] as List?) ?? const [])
                .cast<Map<String, dynamic>>();
            return BoundedBody(
              maxWidth: 820,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _Panel(
                    title: 'Appointments — last 8 weeks',
                    child: _WeeklyChart(weeks: weeks),
                  ),
                  const SizedBox(height: 16),
                  _Panel(
                    title: 'Top conditions',
                    child: _TopConditions(conditions: conditions),
                  ),
                  const SizedBox(height: 16),
                  _Panel(
                    title: 'Appointments by status',
                    child: _StatusBreakdown(statuses: statuses),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Scrollable extends StatelessWidget {
  const _Scrollable({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      ListView(children: [const SizedBox(height: 160), Center(child: child)]);
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: scheme.onSurface,
              )),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Weekly appointments — stacked bars (completed + cancelled)
// ---------------------------------------------------------------------------

class _WeeklyChart extends StatelessWidget {
  const _WeeklyChart({required this.weeks});
  final List<Map<String, dynamic>> weeks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var maxTotal = 1;
    var grandCompleted = 0;
    var grandCancelled = 0;
    for (final w in weeks) {
      final t = (w['total'] as num?)?.toInt() ?? 0;
      if (t > maxTotal) maxTotal = t;
      grandCompleted += (w['completed'] as num?)?.toInt() ?? 0;
      grandCancelled += (w['cancelled'] as num?)?.toInt() ?? 0;
    }
    if (weeks.isEmpty) {
      return Text('No appointments in this period.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13));
    }
    return Column(
      children: [
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final w in weeks)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _WeekBar(
                      completed: (w['completed'] as num?)?.toInt() ?? 0,
                      cancelled: (w['cancelled'] as num?)?.toInt() ?? 0,
                      total: (w['total'] as num?)?.toInt() ?? 0,
                      maxTotal: maxTotal,
                      label: w['label'] as String? ?? '',
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _LegendDot(color: MedThruTheme.coral, label: 'Completed', value: grandCompleted),
            const SizedBox(width: 20),
            _LegendDot(color: scheme.outline, label: 'Cancelled', value: grandCancelled),
          ],
        ),
      ],
    );
  }
}

class _WeekBar extends StatelessWidget {
  const _WeekBar({
    required this.completed,
    required this.cancelled,
    required this.total,
    required this.maxTotal,
    required this.label,
  });
  final int completed, cancelled, total, maxTotal;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(total == 0 ? '' : '$total',
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final barH = maxTotal == 0 ? 0.0 : (total / maxTotal) * c.maxHeight;
            final completedH = total == 0 ? 0.0 : (completed / total) * barH;
            final cancelledH = barH - completedH;
            return Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (cancelledH > 0)
                  Container(
                    height: cancelledH,
                    decoration: BoxDecoration(
                      color: scheme.outline,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                  ),
                if (completedH > 0)
                  Container(
                    height: completedH,
                    decoration: BoxDecoration(
                      color: MedThruTheme.coral,
                      borderRadius: cancelledH > 0
                          ? null
                          : const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                  ),
              ],
            );
          }),
        ),
        const SizedBox(height: 6),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Top conditions — horizontal bars
// ---------------------------------------------------------------------------

class _TopConditions extends StatelessWidget {
  const _TopConditions({required this.conditions});
  final List<Map<String, dynamic>> conditions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (conditions.isEmpty) {
      return Text('No diagnoses recorded yet.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13));
    }
    final maxCount = conditions
        .map((c) => (c['count'] as num?)?.toInt() ?? 0)
        .fold<int>(1, (a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final c in conditions)
          _HBar(
            label: c['name'] as String? ?? '',
            count: (c['count'] as num?)?.toInt() ?? 0,
            fraction: ((c['count'] as num?)?.toInt() ?? 0) / maxCount,
            color: MedThruTheme.coral,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Status breakdown — horizontal bars, coloured per status
// ---------------------------------------------------------------------------

const _statusOrder = ['requested', 'confirmed', 'completed', 'cancelled', 'rejected'];
const _statusLabels = {
  'requested': 'Pending',
  'confirmed': 'Confirmed',
  'completed': 'Completed',
  'cancelled': 'Cancelled',
  'rejected': 'Rejected',
};

Color _statusColor(String s) {
  switch (s) {
    case 'completed':
      return MedThruTheme.green;
    case 'confirmed':
      return MedThruTheme.teal;
    case 'requested':
      return MedThruTheme.amber;
    case 'rejected':
      return MedThruTheme.danger;
    default:
      return const Color(0xFF8A8FA3); // cancelled — muted
  }
}

class _StatusBreakdown extends StatelessWidget {
  const _StatusBreakdown({required this.statuses});
  final List<Map<String, dynamic>> statuses;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = <String, int>{};
    for (final s in statuses) {
      counts[s['status'] as String? ?? ''] = (s['count'] as num?)?.toInt() ?? 0;
    }
    final present = _statusOrder.where((s) => (counts[s] ?? 0) > 0).toList();
    if (present.isEmpty) {
      return Text('No appointments yet.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13));
    }
    final maxCount =
        present.map((s) => counts[s]!).fold<int>(1, (a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final s in present)
          _HBar(
            label: _statusLabels[s] ?? s,
            count: counts[s]!,
            fraction: counts[s]! / maxCount,
            color: _statusColor(s),
          ),
      ],
    );
  }
}

/// One horizontal bar row: label, a proportional bar over a track, and a count.
class _HBar extends StatelessWidget {
  const _HBar({
    required this.label,
    required this.count,
    required this.fraction,
    required this.color,
  });
  final String label;
  final int count;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                height: 14,
                color: scheme.surfaceContainerHigh,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.02, 1.0),
                  child: Container(color: color),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 26,
            child: Text('$count',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label, required this.value});
  final Color color;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Text('$value',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w900, color: scheme.onSurface)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
