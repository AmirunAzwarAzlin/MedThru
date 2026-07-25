import 'package:flutter/material.dart';
import '../../api.dart';
import '../../pdf_export.dart';
import '../../readings.dart';
import '../../theme.dart';
import '../../widgets.dart';
import '../patient/add_note_screen.dart';
import '../messages/conversation_screen.dart';
import 'audit_screen.dart';
import '../health_records/health_record_list_screen.dart';
import '../health_records/vitals_record_screen.dart';

/// A read-only view of a patient's record, reached from the doctor
/// directory — so unlike [PatientScreen], nothing here depends on a card
/// token. Actions are limited to what a doctor can legitimately do without
/// the card in hand: add a clinical note, reissue or revoke a lost card,
/// and review access history.
class PatientSummaryScreen extends StatefulWidget {
  const PatientSummaryScreen({
    super.key,
    required this.patientId,
    required this.patientName,
  });

  final int patientId;
  final String patientName;

  @override
  State<PatientSummaryScreen> createState() => _PatientSummaryScreenState();
}

class _PatientSummaryScreenState extends State<PatientSummaryScreen> {
  late Future<Map<String, dynamic>> _patient;
  late Future<List<Map<String, dynamic>>> _notes;
  late Future<List<Map<String, dynamic>>> _appointments;
  late Future<List<Map<String, dynamic>>> _readings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _patient = MedThruApi.instance.getPatientById(widget.patientId);
    _patient.ignore();
    _notes = MedThruApi.instance.getNotes(widget.patientId);
    _notes.ignore();
    _appointments = MedThruApi.instance.getAppointmentsForPatient(widget.patientId);
    _appointments.ignore();
    _readings = MedThruApi.instance.getReadings(widget.patientId);
    _readings.ignore();
  }

  Future<void> _addUpdate() async {
    final note = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => AddNoteScreen(patientId: widget.patientId)),
    );
    if (note != null && mounted) {
      setState(() => _notes = MedThruApi.instance.getNotes(widget.patientId));
    }
  }

  Future<void> _reissueCard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.credit_card_off_outlined),
        title: const Text('Reissue card?'),
        content: Text(
          'The current card for ${widget.patientName} will stop working '
          'immediately. A new token will be issued.',
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
      final result = await MedThruApi.instance.reissueCard(widget.patientId);
      if (!mounted) return;
      await showCardTokenDialog(
        context,
        token: result.cardToken,
        patientName: widget.patientName,
        isReissue: true,
      );
      if (!mounted) return;
      setState(_load);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _revokeCard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.block),
        title: const Text('Revoke card?'),
        content: Text(
          'The current card for ${widget.patientName} will stop working '
          'immediately, with no replacement issued.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await MedThruApi.instance.revokeCard(widget.patientId);
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Card revoked.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  /// Permanent, no undo — the doctor must type the patient's exact name
  /// before the delete button in the dialog will even enable.
  Future<void> _deletePatient() async {
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
          title: const Text('Delete this patient?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This permanently removes ${widget.patientName}\'s entire record — '
                'card, notes, readings, health records, appointments and access '
                'history. This cannot be undone.',
              ),
              const SizedBox(height: 16),
              Text(
                'Type "${widget.patientName}" to confirm.',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: typed,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'Patient\'s full name'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: typed.text.trim() == widget.patientName
                  ? () => Navigator.pop(context, true)
                  : null,
              style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await MedThruApi.instance.deletePatient(widget.patientId);
      if (!mounted) return;
      Navigator.pop(context); // back to the directory
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.patientName}\'s record was deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  String _val(Map<String, dynamic> p, String key) {
    final v = p[key];
    return (v == null || (v is String && v.isEmpty)) ? '—' : v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.patientName),
        actions: [
          IconButton(
            tooltip: 'Access history',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AuditScreen(
                  patientId: widget.patientId,
                  patientName: widget.patientName,
                ),
              ),
            ),
          ),
        ],
      ),
      body: BoundedBody(
        maxWidth: 640,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _patient,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final p = snap.data;
            if (snap.hasError || p == null) {
              return CenteredMessage(
                icon: Icons.error_outline,
                title: 'Could not load this patient',
                subtitle: snap.error?.toString().replaceFirst('Exception: ', ''),
              );
            }

            final cardActive = p['card_preview'] != null;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        widget.patientName.isNotEmpty
                            ? widget.patientName[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.patientName,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text(
                            'DOB ${_val(p, 'date_of_birth')} · ${_val(p, 'blood_type')}',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      cardActive ? Icons.credit_card : Icons.credit_card_off_outlined,
                      color: cardActive ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _addUpdate,
                      icon: const Icon(Icons.note_add_outlined, size: 18),
                      label: const Text('Add update'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => exportPatientSummary(context, p),
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: const Text('Export summary'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ConversationScreen(
                            patientId: widget.patientId,
                            title: 'Messages · ${widget.patientName}',
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('Messages'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => exportPrescription(context, p),
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('Prescription'),
                    ),
                    if (MedThruApi.instance.isAdmin) ...[
                      OutlinedButton.icon(
                        onPressed: _reissueCard,
                        icon: const Icon(Icons.credit_card_off_outlined, size: 18),
                        label: const Text('Reissue card'),
                      ),
                      if (cardActive)
                        OutlinedButton.icon(
                          onPressed: _revokeCard,
                          icon: Icon(Icons.block, size: 18, color: scheme.error),
                          label: Text('Revoke card', style: TextStyle(color: scheme.error)),
                          style: OutlinedButton.styleFrom(side: BorderSide(color: scheme.error)),
                        ),
                    ],
                  ],
                ),
                if (MedThruApi.instance.isAdmin) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _deletePatient,
                    icon: Icon(Icons.delete_forever_outlined, size: 18, color: scheme.error),
                    label: Text('Delete patient record', style: TextStyle(color: scheme.error)),
                    style: OutlinedButton.styleFrom(side: BorderSide(color: scheme.error)),
                  ),
                ],
                const SizedBox(height: 24),
                _SectionLabel('Health records'),
                const SizedBox(height: 8),
                _SummaryLink(
                  icon: Icons.warning_amber_outlined,
                  label: 'Allergies & intolerances',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HealthRecordListScreen(
                        patientId: widget.patientId,
                        cardToken: null, // doctor summary: read-only, no card in hand
                        config: allergyRecordConfig,
                      ),
                    ),
                  ),
                ),
                _SummaryLink(
                  icon: Icons.medication_outlined,
                  label: 'Medications',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HealthRecordListScreen(
                        patientId: widget.patientId,
                        cardToken: null,
                        config: medicationRecordConfig,
                      ),
                    ),
                  ),
                ),
                _SummaryLink(
                  icon: Icons.vaccines_outlined,
                  label: 'Vaccinations',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HealthRecordListScreen(
                        patientId: widget.patientId,
                        cardToken: null,
                        config: vaccinationRecordConfig,
                      ),
                    ),
                  ),
                ),
                _SummaryLink(
                  icon: Icons.history_edu_outlined,
                  label: 'Medical history',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HealthRecordListScreen(
                        patientId: widget.patientId,
                        cardToken: null,
                        config: medicalHistoryRecordConfig,
                      ),
                    ),
                  ),
                ),
                _SummaryLink(
                  icon: Icons.contact_emergency_outlined,
                  label: 'Emergency contacts',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HealthRecordListScreen(
                        patientId: widget.patientId,
                        cardToken: null,
                        config: emergencyContactRecordConfig,
                      ),
                    ),
                  ),
                ),
                _SummaryLink(
                  icon: Icons.monitor_heart_outlined,
                  label: 'Vital signs & anthropometry',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VitalsRecordScreen(
                        patientId: widget.patientId,
                        cardToken: null,
                        category: ReadingCategory.vital,
                        title: 'Vital signs',
                        emptyLabel: 'No vitals logged yet.',
                        initialType: 'blood_sugar',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _SectionLabel('Appointments'),
                const SizedBox(height: 8),
                _AppointmentsPreview(future: _appointments),
                const SizedBox(height: 24),
                _SectionLabel('Clinical updates'),
                const SizedBox(height: 8),
                _NotesPreview(future: _notes),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant));
  }
}

class _SummaryLink extends StatelessWidget {
  const _SummaryLink({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        onTap: onTap,
        leading: Icon(icon, color: scheme.primary, size: 20),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant, size: 20),
      ),
    );
  }
}

class _AppointmentsPreview extends StatelessWidget {
  const _AppointmentsPreview({required this.future});
  final Future<List<Map<String, dynamic>>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(snap.error.toString().replaceFirst('Exception: ', ''),
              style: TextStyle(color: scheme.error, fontSize: 13));
        }
        final appts = snap.data ?? [];
        if (appts.isEmpty) {
          return Text('No appointments.', style: TextStyle(color: scheme.onSurfaceVariant));
        }
        return Column(
          children: [
            for (final a in appts.take(5))
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${formatAppointmentTime(a['starts_at'] as String)} · ${a['clinic_name']}',
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                    StatusPill(status: a['status'] as String),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NotesPreview extends StatelessWidget {
  const _NotesPreview({required this.future});
  final Future<List<Map<String, dynamic>>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(snap.error.toString().replaceFirst('Exception: ', ''),
              style: TextStyle(color: scheme.error, fontSize: 13));
        }
        final notes = snap.data ?? [];
        if (notes.isEmpty) {
          return Text('No clinical updates.', style: TextStyle(color: scheme.onSurfaceVariant));
        }
        return Column(
          children: [
            for (final n in notes.take(5))
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n['body']?.toString() ?? '', style: const TextStyle(fontSize: 13.5)),
                    const SizedBox(height: 4),
                    Text(
                      '${n['doctor_name'] ?? 'Unknown'} · ${n['created_at'] ?? ''}',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
