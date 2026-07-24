import 'package:flutter/material.dart';
import 'readings.dart';
import 'theme.dart';
import 'trend_chart.dart';

/// Shared building blocks for the Health Records category screens: each
/// category is now its own page (reached by tapping a tile), but they all
/// render the same kind of "who added this, and when" pill, the same
/// loading/error/empty wrapper, and — for vitals and anthropometry — the
/// same trend-card-with-collapsible-history layout.

String whoFor(Map<String, dynamic> row) =>
    row['source'] == 'patient' ? 'Self-reported' : (row['doctor_name'] as String? ?? 'Clinician');

/// A small "who added this, and when" pill, shared across every record type.
class SourcePill extends StatelessWidget {
  const SourcePill({super.key, required this.bySelf, required this.who, required this.date});
  final bool bySelf;
  final String who;
  final String date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: bySelf ? scheme.surfaceContainerHighest : scheme.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(who,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: bySelf ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
              )),
        ),
        const SizedBox(width: 8),
        Text(date, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// A whole scrollable page body: loading / error / empty / list, so each
/// category screen only has to supply how one row renders.
class RecordFutureList extends StatelessWidget {
  const RecordFutureList({
    super.key,
    required this.future,
    required this.itemBuilder,
    required this.emptyLabel,
  });

  final Future<List<Map<String, dynamic>>> future;
  final Widget Function(Map<String, dynamic>) itemBuilder;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(snap.error.toString().replaceFirst('Exception: ', ''),
                  style: TextStyle(color: scheme.error)),
            ),
          );
        }
        final rows = snap.data ?? [];
        if (rows.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(emptyLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [for (final r in rows) itemBuilder(r)],
        );
      },
    );
  }
}

Color severityColor(String? severity) {
  switch (severity?.toLowerCase()) {
    case 'severe':
      return MedThruTheme.iconRed;
    case 'moderate':
      return const Color(0xFFB88407);
    default:
      return MedThruTheme.iconGreen;
  }
}

/// Colour for a lab result's status flag: red for a critical value, amber for
/// anything out of range, green for a normal one.
Color labStatusColor(String? status) {
  switch (status?.toLowerCase()) {
    case 'critical':
      return MedThruTheme.iconRed;
    case 'high':
    case 'low':
    case 'abnormal':
      return const Color(0xFFB88407);
    default:
      return MedThruTheme.iconGreen;
  }
}

/// A label + colour for a "next dose due" date relative to today: overdue reads
/// red, due within a month amber, and anything further off stays muted.
(String, Color) nextDoseStatus(BuildContext context, String due) {
  final scheme = Theme.of(context).colorScheme;
  final d = DateTime.tryParse(due);
  if (d == null) return ('Next dose due $due', scheme.onSurfaceVariant);
  final now = DateTime.now();
  final days = d.difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days < 0) return ('Next dose overdue · $due', MedThruTheme.danger);
  if (days <= 30) return ('Next dose due soon · $due', const Color(0xFFB88407));
  return ('Next dose due $due', scheme.onSurfaceVariant);
}

class AllergyCard extends StatelessWidget {
  const AllergyCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final severity = row['severity'] as String?;
    final reaction = row['reaction'] as String?;
    final note = row['note'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row['allergen'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (severity != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: severityColor(severity).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(severity,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: severityColor(severity))),
                ),
            ],
          ),
          if (reaction != null && reaction.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Reaction: $reaction',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

class MedicationCard extends StatelessWidget {
  const MedicationCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dosage = row['dosage'] as String?;
    final frequency = row['frequency'] as String?;
    final start = row['start_date'] as String?;
    final end = row['end_date'] as String?;
    final note = row['note'] as String?;
    final details = [
      if (dosage != null && dosage.isNotEmpty) dosage,
      if (frequency != null && frequency.isNotEmpty) frequency,
    ].join(' · ');
    final range = start == null && end == null ? null : '${start ?? '—'} to ${end ?? 'ongoing'}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row['name'] as String,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(details, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          if (range != null) ...[
            const SizedBox(height: 3),
            Text(range, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

class VaccinationCard extends StatelessWidget {
  const VaccinationCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dose = row['dose_number'];
    final nextDue = row['next_due'] as String?;
    final note = row['note'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row['vaccine'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (dose != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('Dose $dose',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Administered ${row['administered_at']}',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          if (nextDue != null && nextDue.isNotEmpty) ...[
            const SizedBox(height: 3),
            Builder(builder: (context) {
              final (label, color) = nextDoseStatus(context, nextDue);
              return Row(
                children: [
                  Icon(Icons.event_repeat_outlined, size: 14, color: color),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
                ],
              );
            }),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

class MedicalHistoryCard extends StatelessWidget {
  const MedicalHistoryCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = row['status'] as String?;
    final diagnosedAt = row['diagnosed_at'] as String?;
    final note = row['note'] as String?;
    final resolved = status == 'resolved';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row['condition_name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (status != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (resolved ? MedThruTheme.iconGreen : MedThruTheme.iconBlue)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(resolved ? 'Resolved' : 'Active',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: resolved ? MedThruTheme.iconGreen : MedThruTheme.iconBlue)),
                ),
            ],
          ),
          if (diagnosedAt != null && diagnosedAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Diagnosed $diagnosedAt',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

class EmergencyContactCard extends StatelessWidget {
  const EmergencyContactCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final relationship = row['relationship'] as String?;
    final note = row['note'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row['name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (relationship != null && relationship.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(relationship,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.phone_outlined, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(row['phone'] as String,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ],
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

class LabResultCard extends StatelessWidget {
  const LabResultCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = row['status'] as String?;
    final value = row['value'] as String?;
    final unit = row['unit'] as String?;
    final range = row['reference_range'] as String?;
    final takenAt = row['taken_at'] as String?;
    final note = row['note'] as String?;
    final valueLine = [
      if (value != null && value.isNotEmpty) value,
      if (unit != null && unit.isNotEmpty) unit,
    ].join(' ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row['test_name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (status != null && status.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: labStatusColor(status).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${status[0].toUpperCase()}${status.substring(1)}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: labStatusColor(status)),
                  ),
                ),
            ],
          ),
          if (valueLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(valueLine,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ],
          if (range != null && range.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Reference: $range',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
          if (takenAt != null && takenAt.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text('Taken $takenAt',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          SourcePill(
            bySelf: row['source'] == 'patient',
            who: whoFor(row),
            date: row['created_at']?.toString() ?? '',
          ),
        ],
      ),
    );
  }
}

/// One reading row inside a metric's collapsible history.
class ReadingRow extends StatelessWidget {
  const ReadingRow({super.key, required this.reading, this.onDelete});
  final Map<String, dynamic> reading;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = readingTypes[reading['reading_type'] as String];
    final value = reading['value'] as num;
    final bySelf = reading['source'] == 'patient';
    final who = bySelf ? 'Self-reported' : (reading['doctor_name'] as String? ?? 'Clinician');
    final note = reading['note'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(spec?.icon ?? Icons.monitor_heart_outlined,
              size: 18, color: spec?.color(context) ?? scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${spec?.label ?? reading['reading_type']}: '
                  '${spec?.format(value) ?? value} ${reading['unit']}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 4),
                SourcePill(
                  bySelf: bySelf,
                  who: who,
                  date: reading['taken_at']?.toString() ?? '',
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, size: 18, color: scheme.onSurfaceVariant),
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

/// One measure: headline value plus its trend over time, with its own
/// entries tucked behind a "History" toggle instead of one long combined list.
class TrendCard extends StatefulWidget {
  const TrendCard({
    super.key,
    required this.spec,
    required this.points,
    required this.rows,
    this.onDeleteRow,
  });
  final ReadingType spec;
  final List<TrendPoint> points;

  /// This metric's own entries only, newest first.
  final List<Map<String, dynamic>> rows;

  /// Called with a reading's id when its history row's delete button is
  /// tapped. Null hides the delete affordance entirely.
  final void Function(int id)? onDeleteRow;

  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  bool _historyOpen = false;
  bool _showDaily = true;

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final points = widget.points;
    final rows = widget.rows;
    final scheme = Theme.of(context).colorScheme;
    final latest = points.isEmpty ? null : points.last.v;
    final within = latest == null ? null : spec.withinTypical(latest);

    // Multiple same-day readings (self-checks logged several times a day)
    // make a raw line noisy without adding trend information, so daily
    // averaging is the default; the toggle only appears when it would
    // actually change anything.
    final agg = aggregateDaily(points);
    final hasDenseDays = agg.points.length < points.length;
    final showDaily = hasDenseDays && _showDaily;
    final chartPoints = showDaily ? agg.points : points;
    final chartBand = showDaily ? agg.bands : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: spec.tile(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(spec.icon, color: spec.color(context), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec.label,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15.5,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(spec.typical,
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (latest == null)
                Text('—', style: TextStyle(fontSize: 20, color: scheme.onSurfaceVariant))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${spec.format(latest)} ${spec.unit}',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                    if (within != null)
                      Text(
                        within ? 'within typical range' : 'outside typical range',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: within ? MedThruTheme.iconGreen : MedThruTheme.danger,
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (points.length >= 2) ...[
            const SizedBox(height: 14),
            if (hasDenseDays) ...[
              _DailyToggle(
                showDaily: _showDaily,
                onChanged: (v) => setState(() => _showDaily = v),
              ),
              const SizedBox(height: 8),
            ],
            TrendChart(points: chartPoints, band: chartBand, spec: spec),
          ] else if (points.length == 1) ...[
            const SizedBox(height: 12),
            Text('Log another reading to see a trend.',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _historyOpen = !_historyOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _historyOpen ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _historyOpen ? 'Hide history' : 'History (${rows.length})',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            if (_historyOpen) ...[
              const SizedBox(height: 4),
              for (final r in rows)
                ReadingRow(
                  reading: r,
                  onDelete: widget.onDeleteRow == null
                      ? null
                      : () => widget.onDeleteRow!(r['id'] as int),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Switches a [TrendCard]'s chart between the daily-average default and
/// every raw reading. Only rendered when a metric actually has days with
/// more than one reading — otherwise the two views are identical.
class _DailyToggle extends StatelessWidget {
  const _DailyToggle({required this.showDaily, required this.onChanged});
  final bool showDaily;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('Daily average')),
        ButtonSegment(value: false, label: Text('All readings')),
      ],
      selected: {showDaily},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// The trend-card list for one Health Records reading category (vitals or
/// anthropometry), given the already-fetched rows for the whole patient.
class ReadingCategoryBody extends StatelessWidget {
  const ReadingCategoryBody({
    super.key,
    required this.rows,
    required this.category,
    this.onDeleteRow,
  });
  final List<Map<String, dynamic>> rows;
  final ReadingCategory category;
  final void Function(int id)? onDeleteRow;

  @override
  Widget build(BuildContext context) {
    final specs = readingTypes.values.where((t) => t.category == category).toList();

    List<Map<String, dynamic>> rowsFor(String type) =>
        rows.where((r) => r['reading_type'] == type).toList();

    List<TrendPoint> pointsFor(String type) => rowsFor(type)
        .map((r) => (
              t: DateTime.parse(r['taken_at'] as String),
              v: (r['value'] as num).toDouble(),
            ))
        .toList()
        .reversed
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final spec in specs)
          TrendCard(
            spec: spec,
            points: pointsFor(spec.key),
            rows: rowsFor(spec.key),
            onDeleteRow: onDeleteRow,
          ),
      ],
    );
  }
}
