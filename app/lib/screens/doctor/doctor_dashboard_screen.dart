import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart';
import 'patient_directory_screen.dart';
import 'patient_summary_screen.dart';

/// The doctor's landing dashboard — a practice-at-a-glance view: today's
/// schedule, headline KPIs, patient demographics, this month's appointment
/// tallies and the newest arrivals. Every figure is real, served in one call
/// by `GET /api/doctor/dashboard`.
///
/// Responsive by design: wide screens (desktop / web / tablet) get a two-column
/// layout with the schedule as a left rail; phones reflow to a single column.
class DoctorDashboardScreen extends StatefulWidget {
  const DoctorDashboardScreen({super.key, required this.doctorName});

  final String doctorName;

  @override
  State<DoctorDashboardScreen> createState() => _DoctorDashboardScreenState();
}

class _DoctorDashboardScreenState extends State<DoctorDashboardScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getDoctorDashboard();
    _future.ignore();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(_load),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _ScrollableCenter(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ScrollableCenter(
              child: CenteredMessage(
                icon: Icons.error_outline,
                title: 'Could not load the dashboard',
                subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
                action: OutlinedButton.icon(
                  onPressed: () => setState(_load),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            );
          }
          return _DashboardBody(
            data: snap.data ?? const {},
            doctorName: widget.doctorName,
          );
        },
      ),
    );
  }
}

/// Keeps loading/error states scrollable so pull-to-refresh still works.
class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 160),
        Center(child: child),
      ],
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.data, required this.doctorName});

  final Map<String, dynamic> data;
  final String doctorName;

  @override
  Widget build(BuildContext context) {
    final kpis = (data['kpis'] as Map?)?.cast<String, dynamic>() ?? const {};
    final today = (data['today'] as Map?)?.cast<String, dynamic>() ?? const {};
    final appts = ((today['appointments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final demographics =
        (data['demographics'] as Map?)?.cast<String, dynamic>() ?? const {};
    final month =
        (data['appointmentsThisMonth'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final newPatients = ((data['newPatients'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    final greeting = _Greeting(name: doctorName);
    final schedule = _ScheduleCard(appointments: appts);
    final kpiGrid = _KpiGrid(kpis: kpis);
    final demographicsCard = _DemographicsCard(demographics: demographics);
    final appointmentsCard = _AppointmentsCard(month: month);
    final newPatientsCard = _NewPatientsCard(patients: newPatients);

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 1000;
        if (wide) {
          // Two columns: a fixed schedule rail beside the metric cards.
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 340,
                  child: Column(
                    children: [greeting, const SizedBox(height: 16), schedule],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      kpiGrid,
                      const SizedBox(height: 16),
                      // Demographics and the month chart sit side by side when
                      // there's room, stacking below the KPI row.
                      _TwoUp(left: demographicsCard, right: appointmentsCard),
                      const SizedBox(height: 16),
                      newPatientsCard,
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        // Single column: everything stacks, KPIs stay a compact 2-up grid.
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            greeting,
            const SizedBox(height: 16),
            kpiGrid,
            const SizedBox(height: 16),
            schedule,
            const SizedBox(height: 16),
            demographicsCard,
            const SizedBox(height: 16),
            appointmentsCard,
            const SizedBox(height: 16),
            newPatientsCard,
          ],
        );
      },
    );
  }
}

/// Lays two cards side by side above ~720px, stacked below.
class _TwoUp extends StatelessWidget {
  const _TwoUp({required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 720) {
          return Column(children: [left, const SizedBox(height: 16), right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Greeting hero
// ---------------------------------------------------------------------------

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name});
  final String name;

  String get _shortName {
    // "Dr. Joanne Carter" -> "Dr. Carter"; a bare name is left as-is.
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Doctor';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.first.toLowerCase().startsWith('dr') && parts.length > 2) {
      return '${parts.first} ${parts.last}';
    }
    return trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 26),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MedThruTheme.coral, MedThruTheme.coralDeep],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hello, $_shortName',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Here's what's happening in your practice today.",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.today_outlined, size: 15, color: Colors.white),
                const SizedBox(width: 7),
                Text(
                  _todayLabel(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _todayLabel() {
    final now = DateTime.now();
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}';
  }
}

// ---------------------------------------------------------------------------
// KPI grid
// ---------------------------------------------------------------------------

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.kpis});
  final Map<String, dynamic> kpis;

  int _int(String key) => (kpis[key] as num?)?.toInt() ?? 0;
  int? _delta(String key) => (kpis[key] as num?)?.toInt();

  @override
  Widget build(BuildContext context) {
    final cards = [
      _KpiCard(
        label: "Today's appointments",
        value: '${_int('todaysAppointments')}',
        icon: Icons.event_available_outlined,
        color: MedThruTheme.teal,
      ),
      _KpiCard(
        label: 'Patients this month',
        value: '${_int('patientsThisMonth')}',
        icon: Icons.groups_outlined,
        color: MedThruTheme.green,
        deltaPct: _delta('patientsDeltaPct'),
      ),
      _KpiCard(
        label: 'Prescriptions this week',
        value: '${_int('prescriptionsThisWeek')}',
        icon: Icons.medication_outlined,
        color: MedThruTheme.iconPurple,
        deltaPct: _delta('prescriptionsDeltaPct'),
      ),
      _KpiCard(
        label: 'Confirmed this week',
        value: '${_int('confirmedThisWeek')}',
        icon: Icons.verified_outlined,
        color: MedThruTheme.amber,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        // Four across on very wide areas, otherwise two across.
        final cols = c.maxWidth >= 720 ? 4 : 2;
        const gap = 12.0;
        final tileWidth = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: tileWidth, child: card),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.deltaPct,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final int? deltaPct;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: MedThruTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const Spacer(),
              if (deltaPct != null) _DeltaPill(pct: deltaPct!),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurfaceVariant,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeltaPill extends StatelessWidget {
  const _DeltaPill({required this.pct});
  final int pct;

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    // Positive deltas get the lime pill with dark text — the reference's
    // signature highlight. Negatives use the emergency-red wash.
    final bg = up
        ? MedThruTheme.lime
        : MedThruTheme.danger.withValues(alpha: 0.14);
    final fg = up ? MedThruTheme.ink : MedThruTheme.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12,
            color: fg,
          ),
          const SizedBox(width: 2),
          Text(
            '${pct.abs()}%',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card scaffold
// ---------------------------------------------------------------------------

/// Shared wrapper for the panel-style cards (schedule, demographics, etc.).
class _Panel extends StatelessWidget {
  const _Panel({required this.title, this.trailing, required this.child});
  final String title;
  final Widget? trailing;
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
        boxShadow: MedThruTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Today's schedule
// ---------------------------------------------------------------------------

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.appointments});
  final List<Map<String, dynamic>> appointments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Panel(
      title: "Today's schedule",
      trailing: _CountBadge(count: appointments.length),
      child: appointments.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Row(
                children: [
                  Icon(
                    Icons.event_busy_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No appointments booked for today.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: [for (final a in appointments) _ScheduleTile(appt: a)],
            ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.appt});
  final Map<String, dynamic> appt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = appt['patient_name'] as String? ?? 'Patient';
    final reason = (appt['reason'] as String?)?.trim();
    final status = appt['status'] as String? ?? 'confirmed';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              _timeOf(appt['starts_at'] as String? ?? ''),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      StatusPill(status: status),
                    ],
                  ),
                  if (reason != null && reason.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      reason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: MedThruTheme.coral.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: MedThruTheme.coralDeep,
        ),
      ),
    );
  }
}

/// "8:15 AM" from a stored "YYYY-MM-DD HH:MM" wall-clock string.
String _timeOf(String startsAt) {
  final parsed = DateTime.tryParse(startsAt.replaceFirst(' ', 'T'));
  if (parsed == null) return startsAt;
  final h12 = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
  final ampm = parsed.hour < 12 ? 'AM' : 'PM';
  return '$h12:${parsed.minute.toString().padLeft(2, '0')} $ampm';
}

// ---------------------------------------------------------------------------
// Demographics donut
// ---------------------------------------------------------------------------

/// Age buckets in display order, each with its ring colour — a purple→blue
/// gradient capped with lime, echoing the reference donut.
const _ageOrder = <String, Color>{
  '0-12': Color(0xFF4E44A8), // deep purple
  '13-18': Color(0xFF6C63C7), // brand purple
  '19-35': Color(0xFF8F86E8), // light purple
  '36-50': Color(0xFF5B8DEF), // blue
  '51-65': Color(0xFF9BC1F5), // light blue
  '65+': Color(0xFFC7ED4B), // lime
};

class _DemographicsCard extends StatelessWidget {
  const _DemographicsCard({required this.demographics});
  final Map<String, dynamic> demographics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = (demographics['total'] as num?)?.toInt() ?? 0;
    final ages =
        (demographics['ageBuckets'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final gender =
        (demographics['gender'] as Map?)?.cast<String, dynamic>() ?? const {};
    final female = (gender['female'] as num?)?.toInt() ?? 0;
    final male = (gender['male'] as num?)?.toInt() ?? 0;
    final genderKnown = female + male;

    final segments = [
      for (final entry in _ageOrder.entries)
        (color: entry.value, value: (ages[entry.key] as num?)?.toInt() ?? 0),
    ];

    return _Panel(
      title: 'Demographics',
      child: total == 0
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'No patients registered yet.',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13.5,
                ),
              ),
            )
          : Column(
              children: [
                Center(
                  child: SizedBox(
                    height: 170,
                    width: 170,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size(170, 170),
                          painter: _DonutPainter(
                            segments: [
                              for (final s in segments)
                                (color: s.color, value: s.value.toDouble()),
                            ],
                            trackColor: scheme.surfaceContainerHigh,
                          ),
                        ),
                        // Centre: gender split when we have it, else headcount.
                        if (genderKnown > 0)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _CentreStat(
                                pct: (female / genderKnown * 100).round(),
                                label: 'Female',
                              ),
                              const SizedBox(height: 4),
                              _CentreStat(
                                pct: (male / genderKnown * 100).round(),
                                label: 'Male',
                              ),
                            ],
                          )
                        else
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$total',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -1,
                                  color: scheme.onSurface,
                                ),
                              ),
                              Text(
                                'Patients',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Age legend, two columns.
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    for (final entry in _ageOrder.entries)
                      SizedBox(
                        width: 120,
                        child: _LegendRow(
                          color: entry.value,
                          label: '${entry.key} years',
                          count: (ages[entry.key] as num?)?.toInt() ?? 0,
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _CentreStat extends StatelessWidget {
  const _CentreStat({required this.pct, required this.label});
  final int pct;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$pct%',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            height: 1,
            color: scheme.onSurface,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.count,
  });
  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.segments, required this.trackColor});

  final List<({Color color, double value})> segments;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;
    const stroke = 20.0;
    final ringRect = Rect.fromCircle(
      center: center,
      radius: radius - stroke / 2,
    );

    // Background track.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawCircle(center, radius - stroke / 2, track);

    final total = segments.fold<double>(0, (s, seg) => s + seg.value);
    if (total <= 0) return;

    const gap = 0.04; // radians of spacing between segments
    var start = -math.pi / 2; // 12 o'clock
    for (final seg in segments) {
      if (seg.value <= 0) continue;
      final sweep = (seg.value / total) * (2 * math.pi) - gap;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = seg.color;
      canvas.drawArc(ringRect, start + gap / 2, sweep, false, paint);
      start += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.segments != segments || old.trackColor != trackColor;
}

// ---------------------------------------------------------------------------
// Appointments this month (bar chart)
// ---------------------------------------------------------------------------

class _AppointmentsCard extends StatelessWidget {
  const _AppointmentsCard({required this.month});
  final Map<String, dynamic> month;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final completed = (month['completed'] as num?)?.toInt() ?? 0;
    final cancelled = (month['cancelled'] as num?)?.toInt() ?? 0;
    final series = ((month['series'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return _Panel(
      title: 'Appointments this month',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 120,
            child: series.isEmpty
                ? Center(
                    child: Text(
                      'No appointments this month yet.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  )
                : _BarChart(series: series),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _LegendDot(
                color: MedThruTheme.coral,
                label: 'Completed',
                value: completed,
              ),
              const SizedBox(width: 22),
              _LegendDot(
                color: scheme.outline,
                label: 'Cancelled',
                value: cancelled,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    required this.value,
  });
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
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.series});
  final List<Map<String, dynamic>> series;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var maxVal = 1;
    for (final d in series) {
      final total =
          ((d['completed'] as num?)?.toInt() ?? 0) +
          ((d['cancelled'] as num?)?.toInt() ?? 0);
      if (total > maxVal) maxVal = total;
    }
    return LayoutBuilder(
      builder: (context, c) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final d in series)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: _StackedBar(
                    completed: (d['completed'] as num?)?.toInt() ?? 0,
                    cancelled: (d['cancelled'] as num?)?.toInt() ?? 0,
                    maxVal: maxVal,
                    maxHeight: c.maxHeight,
                    cancelledColor: scheme.outline,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StackedBar extends StatelessWidget {
  const _StackedBar({
    required this.completed,
    required this.cancelled,
    required this.maxVal,
    required this.maxHeight,
    required this.cancelledColor,
  });

  final int completed;
  final int cancelled;
  final int maxVal;
  final double maxHeight;
  final Color cancelledColor;

  @override
  Widget build(BuildContext context) {
    final total = completed + cancelled;
    final barHeight = maxVal == 0 ? 0.0 : (total / maxVal) * maxHeight;
    final completedH = total == 0 ? 0.0 : (completed / total) * barHeight;
    final cancelledH = barHeight - completedH;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (cancelledH > 0)
          Container(
            height: cancelledH,
            decoration: BoxDecoration(
              color: cancelledColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
          ),
        if (completedH > 0)
          Container(
            height: completedH,
            decoration: BoxDecoration(
              color: MedThruTheme.coral,
              borderRadius: cancelledH > 0
                  ? null
                  : const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// New patients
// ---------------------------------------------------------------------------

class _NewPatientsCard extends StatelessWidget {
  const _NewPatientsCard({required this.patients});
  final List<Map<String, dynamic>> patients;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Panel(
      title: 'New patients',
      trailing: TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PatientDirectoryScreen()),
        ),
        child: const Text('View all'),
      ),
      child: patients.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'No patients registered yet.',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13.5,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth >= 640 ? 2 : 1;
                const gap = 12.0;
                final tileWidth = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final p in patients)
                      SizedBox(
                        width: tileWidth,
                        child: _NewPatientTile(patient: p),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _NewPatientTile extends StatelessWidget {
  const _NewPatientTile({required this.patient});
  final Map<String, dynamic> patient;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = patient['full_name'] as String? ?? 'Patient';
    final age = (patient['age'] as num?)?.toInt();
    final reason = (patient['reason'] as String?)?.trim();
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PatientSummaryScreen(
            patientId: patient['id'] as int,
            patientName: name,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: MedThruTheme.teal.withValues(alpha: 0.18),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: MedThruTheme.tealDeep,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (age != null)
                  Text(
                    '$age yrs',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              reason == null || reason.isEmpty
                  ? 'No visit reason on file.'
                  : reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
