import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';
import '../appointments/reschedule_screen.dart';

/// Doctor-only console for ruling on appointment requests. Requests that hold a
/// slot wait here until confirmed or rejected; the filter also surfaces the
/// confirmed and past bookings.
class AppointmentQueueScreen extends StatefulWidget {
  const AppointmentQueueScreen({super.key});

  @override
  State<AppointmentQueueScreen> createState() => _AppointmentQueueScreenState();
}

class _AppointmentQueueScreenState extends State<AppointmentQueueScreen> {
  // Filters map to the server's status values.
  static const _filters = [
    ('requested', 'Pending'),
    ('reschedule_requested', 'Reschedule pending'),
    ('confirmed', 'Confirmed'),
    ('completed', 'Completed'),
    ('rejected', 'Rejected'),
    ('cancelled', 'Cancelled'),
  ];

  String _status = 'requested';
  late Future<List<Map<String, dynamic>>> _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _queue = MedThruApi.instance.getAppointmentQueue(status: _status);
    _queue.ignore();
  }

  Future<void> _decide(
      Map<String, dynamic> appt, String decision, String verb) async {
    try {
      await MedThruApi.instance.decideAppointment(appt['id'] as int, decision);
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Appointment $verb.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _reschedule(Map<String, dynamic> appt) async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => RescheduleScreen(appointment: appt)),
    );
    if (updated != null && mounted) {
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reschedule proposed — waiting on the patient to confirm.')),
      );
    }
  }

  Future<void> _respondToReschedule(Map<String, dynamic> appt, bool accept) async {
    try {
      await MedThruApi.instance.respondToReschedule(appt['id'] as int, accept);
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(accept ? 'New time accepted.' : 'Kept the original time.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Appointment requests')),
      body: BoundedBody(
        maxWidth: 640,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (value, label) in _filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _status == value,
                          onSelected: (_) => setState(() {
                            _status = value;
                            _load();
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => setState(_load),
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _queue,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return CenteredMessage(
                        icon: Icons.error_outline,
                        title: 'Could not load requests',
                        subtitle: snap.error
                            .toString()
                            .replaceFirst('Exception: ', ''),
                      );
                    }
                    final appts = snap.data ?? const [];
                    if (appts.isEmpty) {
                      return ListView(
                        // Keep pull-to-refresh working when the list is empty.
                        children: [
                          const SizedBox(height: 80),
                          CenteredMessage(
                            icon: Icons.event_available_outlined,
                            title: 'Nothing here',
                            subtitle: 'No $_status appointments.',
                          ),
                        ],
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        for (final a in appts)
                          _QueueCard(
                            appt: a,
                            onConfirm: a['status'] == 'requested'
                                ? () => _decide(a, 'confirmed', 'confirmed')
                                : null,
                            onReject: a['status'] == 'requested'
                                ? () => _decide(a, 'rejected', 'rejected')
                                : null,
                            onComplete: a['status'] == 'confirmed'
                                ? () => _decide(a, 'completed', 'marked complete')
                                : null,
                            // A pending reschedule still holds its original
                            // slot, so it can be called off without settling
                            // the proposal first.
                            onCancel: (a['status'] == 'confirmed' ||
                                    a['status'] == 'reschedule_requested')
                                ? () => _decide(a, 'cancelled', 'cancelled')
                                : null,
                            onReschedule: a['status'] == 'confirmed'
                                ? () => _reschedule(a)
                                : null,
                            onAcceptReschedule:
                                a['status'] == 'reschedule_requested' && a['proposed_by'] == 'patient'
                                    ? () => _respondToReschedule(a, true)
                                    : null,
                            onDeclineReschedule:
                                a['status'] == 'reschedule_requested' && a['proposed_by'] == 'patient'
                                    ? () => _respondToReschedule(a, false)
                                    : null,
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({
    required this.appt,
    this.onConfirm,
    this.onReject,
    this.onComplete,
    this.onCancel,
    this.onReschedule,
    this.onAcceptReschedule,
    this.onDeclineReschedule,
  });

  final Map<String, dynamic> appt;
  final VoidCallback? onConfirm;
  final VoidCallback? onReject;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;
  final VoidCallback? onReschedule;
  final VoidCallback? onAcceptReschedule;
  final VoidCallback? onDeclineReschedule;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reason = appt['reason'] as String?;
    final hasActions = onConfirm != null ||
        onReject != null ||
        onComplete != null ||
        onCancel != null ||
        onReschedule != null ||
        onAcceptReschedule != null ||
        onDeclineReschedule != null;
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
                    appt['patient_name'] as String,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface),
                  ),
                ),
                StatusPill(status: appt['status'] as String),
              ],
            ),
            const SizedBox(height: 8),
            _line(scheme, Icons.schedule,
                formatAppointmentTime(appt['starts_at'] as String)),
            const SizedBox(height: 4),
            _line(scheme, Icons.local_hospital_outlined,
                appt['clinic_name'] as String),
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              _line(scheme, Icons.notes, reason),
            ],
            // Both sides can propose, and both land in this tab — so say which
            // one did, rather than crediting the patient for the doctor's own
            // proposal.
            if (appt['status'] == 'reschedule_requested' &&
                appt['proposed_starts_at'] != null &&
                appt['proposed_by'] == 'patient') ...[
              const SizedBox(height: 4),
              _line(scheme, Icons.sync_alt,
                  'Patient proposed ${formatAppointmentTime(appt['proposed_starts_at'] as String)}'),
            ],
            if (appt['status'] == 'reschedule_requested' &&
                appt['proposed_starts_at'] != null &&
                appt['proposed_by'] == 'doctor') ...[
              const SizedBox(height: 4),
              _line(scheme, Icons.sync_alt,
                  'You proposed ${formatAppointmentTime(appt['proposed_starts_at'] as String)}'),
            ],
            if (hasActions) ...[
              const Divider(height: 22),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  if (onDeclineReschedule != null)
                    TextButton.icon(
                      onPressed: onDeclineReschedule,
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Keep original time'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                  if (onAcceptReschedule != null)
                    FilledButton.icon(
                      onPressed: onAcceptReschedule,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Accept new time'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    ),
                  if (onReschedule != null)
                    TextButton.icon(
                      onPressed: onReschedule,
                      icon: const Icon(Icons.sync_alt, size: 18),
                      label: const Text('Propose reschedule'),
                    ),
                  if (onReject != null)
                    TextButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Reject'),
                      style:
                          TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                  if (onCancel != null)
                    TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.event_busy_outlined, size: 18),
                      label: const Text('Cancel'),
                      style:
                          TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                  if (onComplete != null)
                    FilledButton.tonalIcon(
                      onPressed: onComplete,
                      icon: const Icon(Icons.event_available_outlined, size: 18),
                      label: const Text('Complete'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40)),
                    ),
                  if (onConfirm != null)
                    FilledButton.icon(
                      onPressed: onConfirm,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Confirm'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(ColorScheme scheme, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}
