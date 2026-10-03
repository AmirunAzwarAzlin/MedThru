import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../doctor/patient_summary_screen.dart';

/// The Emergency Response Team's landing screen: a prompt to scan a card,
/// plus a list of patients this responder has recently looked up (for
/// incident recall). Deliberately has none of the clinic dashboard's
/// scheduling/KPI/demographics content — a responder isn't running a
/// practice.
class ResponderHomeScreen extends StatefulWidget {
  const ResponderHomeScreen({super.key, required this.doctorName});
  final String doctorName;

  @override
  State<ResponderHomeScreen> createState() => _ResponderHomeScreenState();
}

class _ResponderHomeScreenState extends State<ResponderHomeScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _load();
    MedThruApi.instance.addListener(_onApiChange);
  }

  @override
  void dispose() {
    MedThruApi.instance.removeListener(_onApiChange);
    super.dispose();
  }

  void _onApiChange() {
    if (mounted) setState(_load);
  }

  void _load() {
    _future = MedThruApi.instance.getRecentLookups();
    _future.ignore();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(_load),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _ScanPrompt(name: widget.doctorName),
          const SizedBox(height: 16),
          _RecentLookupsPanel(future: _future),
        ],
      ),
    );
  }
}

class _ScanPrompt extends StatelessWidget {
  const _ScanPrompt({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 26),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MedThruTheme.teal, MedThruTheme.tealDeep],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ready to respond, $name',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Tap a patient's card to pull up their emergency info instantly.",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentLookupsPanel extends StatelessWidget {
  const _RecentLookupsPanel({required this.future});
  final Future<List<Map<String, dynamic>>> future;

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
          Text(
            'Recently looked up',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Text(
                  snap.error.toString().replaceFirst('Exception: ', ''),
                  style: TextStyle(color: scheme.error, fontSize: 13.5),
                );
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return Text(
                  'No patients looked up yet — tap a card to get started.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
                );
              }
              return Column(
                children: [for (final row in rows) _LookupTile(row: row)],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Renders a SQLite `datetime('now')` timestamp (UTC, no timezone suffix —
/// e.g. "2026-10-03 08:57:40") as a short relative string like "2m ago" or
/// "3h ago", falling back to a short date for anything a week or older.
/// Parses explicitly as UTC so the result is correct regardless of the
/// device's local timezone.
String _timeAgo(String? sqliteUtcTimestamp) {
  if (sqliteUtcTimestamp == null) return '';
  final iso = '${sqliteUtcTimestamp.replaceFirst(' ', 'T')}Z';
  final then = DateTime.tryParse(iso);
  if (then == null) return '';
  final diff = DateTime.now().toUtc().difference(then);
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[then.month - 1]} ${then.day}';
}

class _LookupTile extends StatelessWidget {
  const _LookupTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = row['full_name'] as String? ?? 'Patient';
    final lastViewed = _timeAgo(row['last_viewed'] as String?);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PatientSummaryScreen(
            patientId: row['patient_id'] as int,
            patientName: name,
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
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
            const SizedBox(width: 12),
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
            if (lastViewed.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                lastViewed,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
