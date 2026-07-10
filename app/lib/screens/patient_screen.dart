import 'package:flutter/material.dart';
import '../api.dart';
import '../readings.dart';
import '../theme.dart';
import '../trend_chart.dart';
import '../widgets.dart';
import 'edit_patient_screen.dart';
import 'audit_screen.dart';
import 'add_note_screen.dart';
import 'add_reading_screen.dart';

/// A patient's record, split into tabs reachable from a bottom nav bar so
/// neither a patient nor a doctor has to scroll one long page to find things.
class PatientScreen extends StatefulWidget {
  const PatientScreen({
    super.key,
    required this.patient,
    required this.cardToken,
  });

  final Map<String, dynamic> patient;

  /// Held in memory only, to prove card possession when writing readings.
  /// Never rendered â€” the UI shows `card_preview` instead.
  final String cardToken;

  @override
  State<PatientScreen> createState() => _PatientScreenState();
}

class _PatientScreenState extends State<PatientScreen>
    with SingleTickerProviderStateMixin {
  late Map<String, dynamic> _patient;
  late Future<List<Map<String, dynamic>>> _notes;
  late Future<List<Map<String, dynamic>>> _readings;
  late final TabController _tabs;

  // Tab indices, named so the FAB and dashboard shortcuts stay readable.
  static const _tabCarePlan = 1;
  static const _tabReadings = 2;
  static const _tabUpdates = 3;
  static const _tabEmergency = 4;

  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _patient = widget.patient;
    _tabs = TabController(length: 5, vsync: this);
    // Rebuild so the floating action button matches the visible tab.
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    _loadNotes();
    _loadReadings();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _loadNotes() {
    _notes = MedThruApi.instance.getNotes(_patient['id'] as int);
    // Tabs build lazily, so a request can fail before its FutureBuilder has
    // attached. ignore() marks the error handled without consuming it —
    // the FutureBuilder still receives it and renders its error state.
    _notes.ignore();
  }

  void _loadReadings() {
    _readings = MedThruApi.instance.getReadings(_patient['id'] as int);
    _readings.ignore();
  }

  /// Re-fetch the record and its sub-collections from the server.
  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final fresh = await MedThruApi.instance.lookupByToken(widget.cardToken);
      if (!mounted) return;
      setState(() {
        if (fresh != null) _patient = fresh;
        _loadNotes();
        _loadReadings();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _val(String key) {
    final v = _patient[key];
    return (v == null || (v is String && v.isEmpty)) ? 'â€”' : v.toString();
  }

  bool _has(String key) {
    final v = _patient[key];
    return v != null && !(v is String && v.isEmpty);
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => EditPatientScreen(
          patient: _patient,
          cardToken: widget.cardToken,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _patient = updated);
    }
  }

  /// Lost card: revoke the old token and issue a new one. The replacement is
  /// shown once so it can be written to a blank card.
  Future<void> _reissueCard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.credit_card_off_outlined),
        title: const Text('Reissue card?'),
        content: Text(
          'The current card (â€¢â€¢â€¢â€¢${_patient['card_preview'] ?? '????'}) will '
          'stop working immediately. A new token will be issued for '
          '${_val('full_name')}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(120, 42)),
            child: const Text('Reissue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final result =
          await MedThruApi.instance.reissueCard(_patient['id'] as int);
      if (!mounted) return;
      await showCardTokenDialog(
        context,
        token: result.cardToken,
        patientName: result.patient['full_name'] as String,
        isReissue: true,
      );
      if (!mounted) return;
      // The old token this screen holds is now dead; restart on the new card.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PatientScreen(
            patient: result.patient,
            cardToken: result.cardToken,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _addUpdate() async {
    final note = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddNoteScreen(patientId: _patient['id'] as int),
      ),
    );
    if (note != null && mounted) {
      setState(_loadNotes);
      _tabs.animateTo(_tabUpdates); // jump so the new note is visible
    }
  }

  /// Open to patients, not just doctors.
  Future<void> _addReading() async {
    final reading = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddReadingScreen(token: widget.cardToken),
      ),
    );
    if (reading != null && mounted) {
      setState(_loadReadings);
      _tabs.animateTo(_tabReadings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDoctor = MedThruApi.instance.isLoggedIn;

    final tabs = [
      _HomeTab(
        patient: _patient,
        val: _val,
        has: _has,
        refreshing: _refreshing,
        onRefresh: _refresh,
        onAddReading: _addReading,
        onOpenTab: (i) => _tabs.animateTo(i),
      ),
      _CarePlanTab(val: _val),
      _ReadingsTab(readings: _readings),
      _UpdatesTab(notes: _notes),
      _EmergencyTab(val: _val, has: _has),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_val('full_name')),
        actions: [
          if (isDoctor) ...[
            IconButton(
              tooltip: 'Reissue card (lost or stolen)',
              icon: const Icon(Icons.credit_card_off_outlined),
              onPressed: _reissueCard,
            ),
            IconButton(
              tooltip: 'Access history',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AuditScreen(
                    patientId: _patient['id'] as int,
                    patientName: _val('full_name'),
                  ),
                ),
              ),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          indicatorColor: MedThruTheme.blue,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700),
          tabs: const [
            Tab(icon: Icon(Icons.home_outlined), text: 'Home'),
            Tab(icon: Icon(Icons.event_outlined), text: 'Care plan'),
            Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Readings'),
            Tab(icon: Icon(Icons.timeline_outlined), text: 'Updates'),
            Tab(icon: Icon(Icons.emergency_outlined), text: 'Emergency'),
          ],
        ),
      ),
      body: BoundedBody(
        maxWidth: 640,
        child: TabBarView(controller: _tabs, children: tabs),
      ),
      floatingActionButton: _buildFab(isDoctor),
    );
  }

  /// The action changes with the visible tab. Readings are the one thing a
  /// patient may add, so that button is not gated on being a doctor.
  Widget? _buildFab(bool isDoctor) {
    if (_tabs.index == _tabReadings) {
      return FloatingActionButton.extended(
        onPressed: _addReading,
        icon: const Icon(Icons.add),
        label: const Text('Add reading'),
      );
    }
    if (!isDoctor) return null;
    if (_tabs.index == _tabUpdates) {
      return FloatingActionButton.extended(
        onPressed: _addUpdate,
        icon: const Icon(Icons.add),
        label: const Text('Add update'),
      );
    }
    return FloatingActionButton.extended(
      onPressed: _edit,
      icon: const Icon(Icons.edit),
      label: const Text('Edit record'),
    );
  }
}

// --- Tabs ---

/// Patient dashboard: identity card, quick actions, primary CTA.
class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.patient,
    required this.val,
    required this.has,
    required this.refreshing,
    required this.onRefresh,
    required this.onAddReading,
    required this.onOpenTab,
  });

  final Map<String, dynamic> patient;
  final String Function(String) val;
  final bool Function(String) has;
  final bool refreshing;
  final VoidCallback onRefresh;
  final VoidCallback onAddReading;
  final void Function(int) onOpenTab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _IdentityCard(
          name: val('full_name'),
          dob: val('date_of_birth'),
          preview: val('card_preview'),
          bloodType: val('blood_type'),
          updatedAt: patient['updated_at'] as String?,
          refreshing: refreshing,
          onRefresh: onRefresh,
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Tap your card on a reader to refresh',
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 18),
        if (has('allergies'))
          _AllergyBanner(allergies: patient['allergies'] as String),

        // Quick actions, two per row.
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                icon: Icons.emergency_outlined,
                label: 'Emergency Info',
                color: MedThruTheme.iconRed,
                tile: MedThruTheme.tileRed,
                onTap: () => onOpenTab(_PatientScreenState._tabEmergency),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                icon: Icons.monitor_heart_outlined,
                label: 'My Readings',
                color: MedThruTheme.iconBlue,
                tile: MedThruTheme.tileBlue,
                onTap: () => onOpenTab(_PatientScreenState._tabReadings),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                icon: Icons.event_outlined,
                label: 'Care Plan',
                color: MedThruTheme.iconGreen,
                tile: MedThruTheme.tileGreen,
                onTap: () => onOpenTab(_PatientScreenState._tabCarePlan),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                icon: Icons.timeline_outlined,
                label: 'Clinical Updates',
                color: MedThruTheme.iconPurple,
                tile: MedThruTheme.tilePurple,
                onTap: () => onOpenTab(_PatientScreenState._tabUpdates),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: onAddReading,
          icon: const Icon(Icons.add),
          label: const Text('Add a reading'),
        ),

        // The full medical fields still live here; the dashboard above is a
        // shortcut layer, not a replacement for the record.
        const SizedBox(height: 26),
        Text('MEDICAL DETAILS',
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        FieldCard(
            label: 'Blood type',
            value: val('blood_type'),
            icon: Icons.bloodtype_outlined),
        FieldCard(
            label: 'Allergies',
            value: val('allergies'),
            icon: Icons.warning_amber_outlined),
        FieldCard(
            label: 'Medications',
            value: val('medications'),
            icon: Icons.medication_outlined),
        FieldCard(
            label: 'Conditions',
            value: val('conditions'),
            icon: Icons.monitor_heart_outlined),
      ],
    );
  }
}

/// The hero card: who this is, and the one fact an emergency responder needs.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.name,
    required this.dob,
    required this.preview,
    required this.bloodType,
    required this.updatedAt,
    required this.refreshing,
    required this.onRefresh,
  });

  final String name, dob, preview, bloodType;
  final String? updatedAt;
  final bool refreshing;
  final VoidCallback onRefresh;

  String get _initial =>
      (name.isNotEmpty && name != 'â€”') ? name[0].toUpperCase() : '?';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [MedThruTheme.blue, Color(0xFF1C6FB8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                child: Text(_initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(dob == 'â€”' ? 'Date of birth not set' : 'Born $dob',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12.5)),
                  ],
                ),
              ),
              if (refreshing)
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              else
                InkWell(
                  onTap: onRefresh,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text('Refresh',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.local_hospital_outlined,
                size: 30, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            bloodType == 'â€”' ? 'Blood type unknown' : 'Blood Type  $bloodType',
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text('MED-IC CARD',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('â€¢â€¢â€¢â€¢ â€¢â€¢â€¢â€¢ $preview',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(
            updatedAt == null ? '' : 'Updated ${_pretty(updatedAt!)}',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  static String _pretty(String sqlTimestamp) {
    final t = DateTime.tryParse(sqlTimestamp);
    if (t == null) return sqlTimestamp;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${longDate(t)}, $hh:$mm';
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.tile,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color tile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 124,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? color.withValues(alpha: 0.18) : tile,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon,
                    color: isDark ? tile : color, size: 24),
              ),
              const SizedBox(height: 10),
              // Long labels wrap to two lines; keep them from overflowing.
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CarePlanTab extends StatelessWidget {
  const _CarePlanTab({required this.val});
  final String Function(String) val;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.event_outlined,
          title: 'Care plan',
          subtitle: 'Upcoming appointments and scheduled procedures.',
        ),
        FieldCard(
            label: 'Primary doctor',
            value: val('primary_doctor'),
            icon: Icons.person_outline),
        FieldCard(
            label: 'Next appointment',
            value: val('next_appointment'),
            icon: Icons.event_available_outlined),
        FieldCard(
            label: 'Surgery date',
            value: val('surgery_date'),
            icon: Icons.local_hospital_outlined),
        FieldCard(
            label: 'Current medications',
            value: val('medications'),
            icon: Icons.medication_outlined),
      ],
    );
  }
}

class _ReadingsTab extends StatelessWidget {
  const _ReadingsTab({required this.readings});
  final Future<List<Map<String, dynamic>>> readings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: readings,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return CenteredMessage(
            icon: Icons.error_outline,
            title: 'Could not load readings',
            subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
          );
        }
        final all = snap.data ?? [];

        // The API returns newest first; charts read left-to-right in time.
        List<TrendPoint> pointsFor(String type) => all
            .where((r) => r['reading_type'] == type)
            .map((r) => (
                  t: DateTime.parse(r['taken_at'] as String),
                  v: (r['value'] as num).toDouble(),
                ))
            .toList()
            .reversed
            .toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _TabHeading(
              icon: Icons.monitor_heart_outlined,
              title: 'Readings',
              subtitle: 'Blood sugar, cholesterol and uric acid you log yourself.',
            ),
            // Small multiples: one chart per measure. These share no y-scale
            // (mmol/L vs umol/L), so they must never share an axis.
            for (final spec in readingTypes.values)
              _TrendCard(spec: spec, points: pointsFor(spec.key)),
            const SizedBox(height: 18),
            Text('HISTORY',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (all.isEmpty)
              Container(
                padding: const EdgeInsets.all(28),
                alignment: Alignment.center,
                child: Column(
                  children: [
                    Icon(Icons.monitor_heart_outlined,
                        size: 44, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 10),
                    Text('No readings logged yet.',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              )
            else
              for (final r in all) _ReadingRow(reading: r),
            const SizedBox(height: 12),
            Text(
              'Self-reported readings are informational only and are not a '
              'diagnosis. They do not alter the clinical record.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}

/// One measure: headline value plus its trend over time. The title names the
/// series, so the chart needs no legend.
class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.spec, required this.points});
  final ReadingType spec;
  final List<TrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final latest = points.isEmpty ? null : points.last.v;
    final within = latest == null ? null : spec.withinTypical(latest);

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
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (latest == null)
                Text('â€”',
                    style:
                        TextStyle(fontSize: 20, color: scheme.onSurfaceVariant))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Hero number: the value that matters, in ink not series colour.
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
                          color: within
                              ? MedThruTheme.iconGreen
                              : MedThruTheme.danger,
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (points.length >= 2) ...[
            const SizedBox(height: 14),
            TrendChart(points: points, spec: spec),
          ] else if (points.length == 1) ...[
            const SizedBox(height: 12),
            Text('Log another reading to see a trend.',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({required this.reading});
  final Map<String, dynamic> reading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = readingTypes[reading['reading_type'] as String];
    final value = reading['value'] as num;
    final bySelf = reading['source'] == 'patient';
    final who = bySelf
        ? 'Self-reported'
        : (reading['doctor_name'] as String? ?? 'Clinician');
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
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(note,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: bySelf
                            ? scheme.surfaceContainerHighest
                            : scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(who,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: bySelf
                                ? scheme.onSurfaceVariant
                                : scheme.onPrimaryContainer,
                          )),
                    ),
                    const SizedBox(width: 8),
                    Text(reading['taken_at']?.toString() ?? '',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdatesTab extends StatelessWidget {
  const _UpdatesTab({required this.notes});
  final Future<List<Map<String, dynamic>>> notes;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.timeline_outlined,
          title: 'Clinical updates',
          subtitle: 'Checkups, medication changes and other visit notes.',
        ),
        _NotesTimeline(future: notes),
      ],
    );
  }
}

class _EmergencyTab extends StatelessWidget {
  const _EmergencyTab({required this.val, required this.has});
  final String Function(String) val;
  final bool Function(String) has;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.emergency_outlined,
          title: 'Emergency info',
          subtitle: 'The essentials a first responder needs, up front.',
        ),
        // The two things that matter most in an emergency, made large.
        Row(
          children: [
            Expanded(
              child: _BigStat(
                label: 'Blood type',
                value: val('blood_type'),
                color: MedThruTheme.iconRed,
                tile: MedThruTheme.tileRed,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _BigStat(
                label: 'Allergies',
                value: val('allergies'),
                color: MedThruTheme.iconRed,
                tile: MedThruTheme.tileRed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FieldCard(
            label: 'Conditions',
            value: val('conditions'),
            icon: Icons.monitor_heart_outlined),
        FieldCard(
            label: 'Emergency contact',
            value: val('emergency_contact_name'),
            icon: Icons.contact_emergency_outlined),
        FieldCard(
            label: 'Emergency phone',
            value: val('emergency_contact_phone'),
            icon: Icons.phone_outlined),
      ],
    );
  }
}

// --- Shared pieces ---

class _TabHeading extends StatelessWidget {
  const _TabHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5)),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.label,
    required this.value,
    required this.color,
    required this.tile,
  });
  final String label;
  final String value;
  final Color color;
  final Color tile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? color.withValues(alpha: 0.16) : tile,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: isDark ? tile : color)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
        ],
      ),
    );
  }
}

class _NotesTimeline extends StatelessWidget {
  const _NotesTimeline({required this.future});
  final Future<List<Map<String, dynamic>>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text('Could not load updates.',
              style: TextStyle(color: scheme.error));
        }
        final notes = snap.data ?? [];
        if (notes.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(28),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(Icons.timeline_outlined,
                    size: 44, color: scheme.onSurfaceVariant),
                const SizedBox(height: 10),
                Text('No clinical updates yet.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          );
        }
        return Column(children: [for (final n in notes) _NoteCard(note: n)]);
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});
  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = note['note_type'] as String;
    final meta = noteTypes[type];
    final label = meta?.label ?? type;
    final icon = meta?.icon ?? Icons.note_outlined;
    final who = note['doctor_name'] as String? ?? 'Unknown';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
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
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.primary)),
              const Spacer(),
              Text(note['created_at']?.toString() ?? '',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Text(note['body']?.toString() ?? '',
              style: const TextStyle(fontSize: 15, height: 1.4)),
          const SizedBox(height: 6),
          Text('â€” $who',
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _AllergyBanner extends StatelessWidget {
  const _AllergyBanner({required this.allergies});
  final String allergies;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MedThruTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: MedThruTheme.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: MedThruTheme.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Allergies: $allergies',
              style: const TextStyle(
                  color: MedThruTheme.danger, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
