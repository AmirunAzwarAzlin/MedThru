import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api.dart';
import '../../calendar_export.dart';
import '../../notifications.dart';
import '../../theme.dart';
import '../../widgets.dart';
import '../appointments/book_appointment_screen.dart';

/// Local-only reminder preference, keyed by appointment id — see
/// `notifications.dart` for why this never touches the server.
String _reminderPrefKey(int appointmentId) => 'appt_reminder_$appointmentId';

/// The patient's own appointments, with a way to book more and to cancel any
/// that are still pending or confirmed.
/// Appointments is a pushed screen, reached only from the Home dashboard
/// tile, since it no longer has a permanent tab. Self-contained: it fetches
/// and reloads its own list, the same pattern already used by the Health
/// Records category screens.
class AppointmentsScreen extends StatefulWidget {
  const AppointmentsScreen({super.key, required this.cardToken});
  final String cardToken;

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen> {
  static const _cancellable = {'requested', 'confirmed'};
  late Future<List<Map<String, dynamic>>> _appointments;

  /// Appointment ids with an on-device reminder currently scheduled.
  Set<int> _reminding = {};

  @override
  void initState() {
    super.initState();
    _load();
    _loadReminderPrefs();
  }

  void _load() {
    _appointments = MedThruApi.instance.getMyAppointments(widget.cardToken);
    _appointments.ignore();
  }

  Future<void> _loadReminderPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs
        .getKeys()
        .where((k) => k.startsWith('appt_reminder_'))
        .map((k) => int.tryParse(k.substring('appt_reminder_'.length)))
        .whereType<int>()
        .toSet();
    if (mounted) setState(() => _reminding = ids);
  }

  /// Toggles the on-device reminder for one appointment, an hour before its
  /// start time, and remembers the choice locally so it survives a restart.
  Future<void> _toggleReminder(Map<String, dynamic> appt) async {
    final id = appt['id'] as int;
    final prefs = await SharedPreferences.getInstance();
    if (_reminding.contains(id)) {
      await NotificationService.instance.cancelAppointmentReminder(id);
      await prefs.remove(_reminderPrefKey(id));
      if (mounted) setState(() => _reminding = {..._reminding}..remove(id));
    } else {
      await NotificationService.instance.scheduleAppointmentReminder(
        appointmentId: id,
        clinicName: appt['clinic_name'] as String,
        startsAt: DateTime.parse(appt['starts_at'] as String),
      );
      await prefs.setBool(_reminderPrefKey(id), true);
      if (mounted) setState(() => _reminding = {..._reminding, id});
    }
  }

  Future<void> _book() async {
    final appt = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => BookAppointmentScreen(cardToken: widget.cardToken),
      ),
    );
    if (appt != null && mounted) {
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Appointment requested — awaiting the clinic\'s approval.',
          ),
        ),
      );
    }
  }

  Future<void> _cancel(Map<String, dynamic> appt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel appointment?'),
        content: Text(
          'This frees the slot on ${formatAppointmentTime(appt['starts_at'] as String)} '
          'at ${appt['clinic_name']}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
            child: const Text('Cancel it'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await MedThruApi.instance.cancelAppointment(
        widget.cardToken,
        appt['id'] as int,
      );
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Appointment cancelled.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Appointments')),
      body: BoundedBody(
        maxWidth: 640,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _appointments,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return CenteredMessage(
                icon: Icons.error_outline,
                title: 'Could not load appointments',
                subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
              );
            }
            final appts = snap.data ?? const [];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  'Book ahead at a registered hospital or clinic. A request '
                  'holds its slot until a doctor confirms it.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _book,
                  icon: const Icon(Icons.add),
                  label: const Text('Book an appointment'),
                ),
                const SizedBox(height: 18),
                if (appts.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.event_note_outlined,
                          size: 40,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'No appointments yet',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap “Book an appointment” to schedule one.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final a in appts)
                    _AppointmentCard(
                      appt: a,
                      onCancel: _cancellable.contains(a['status'])
                          ? () => _cancel(a)
                          : null,
                      // Only a confirmed, still-upcoming appointment is worth
                      // reminding about — a pending request might still be
                      // rejected, and a past one has nothing left to remind.
                      remindOn: _reminding.contains(a['id'] as int),
                      onToggleRemind: a['status'] == 'confirmed' &&
                              DateTime.parse(a['starts_at'] as String)
                                  .isAfter(DateTime.now())
                          ? () => _toggleReminder(a)
                          : null,
                      // Exportable while it still holds a slot and hasn't
                      // happened — no point adding a past or dead one to a
                      // calendar.
                      onAddToCalendar: _cancellable.contains(a['status']) &&
                              DateTime.parse(a['starts_at'] as String)
                                  .isAfter(DateTime.now())
                          ? () => exportAppointmentToCalendar(context, a)
                          : null,
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({
    required this.appt,
    this.onCancel,
    this.remindOn = false,
    this.onToggleRemind,
    this.onAddToCalendar,
  });

  final Map<String, dynamic> appt;
  final VoidCallback? onCancel;
  final bool remindOn;

  /// Null hides the reminder toggle entirely (past, cancelled, or still
  /// only requested — nothing worth an on-device reminder yet).
  final VoidCallback? onToggleRemind;

  /// Null hides the "Add to calendar" action (past or no-longer-live).
  final VoidCallback? onAddToCalendar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHospital = appt['clinic_kind'] == 'hospital';
    final note = appt['decision_note'] as String?;
    final reason = appt['reason'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatAppointmentTime(appt['starts_at'] as String),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                StatusPill(status: appt['status'] as String),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  isHospital
                      ? Icons.local_hospital_outlined
                      : Icons.medical_services_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    appt['clinic_name'] as String,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Reason: $reason',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Clinic note: $note',
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (onToggleRemind != null ||
                onAddToCalendar != null ||
                onCancel != null) ...[
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  if (onAddToCalendar != null)
                    TextButton.icon(
                      onPressed: onAddToCalendar,
                      icon: const Icon(Icons.event_available_outlined, size: 16),
                      label: const Text('Add to calendar'),
                    ),
                  if (onToggleRemind != null)
                    TextButton.icon(
                      onPressed: onToggleRemind,
                      icon: Icon(
                        remindOn ? Icons.notifications_active : Icons.notifications_outlined,
                        size: 16,
                      ),
                      label: Text(remindOn ? 'Reminder on' : 'Remind me'),
                    ),
                  if (onCancel != null)
                    TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Cancel'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
