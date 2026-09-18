import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// Propose a new time for a confirmed appointment, choosing from AI-ranked
/// suggestions or picking a slot manually. Used by both apps: [cardToken]
/// non-null means patient mode (reached with the card), null means doctor
/// mode (reached with the doctor's session).
class RescheduleScreen extends StatefulWidget {
  const RescheduleScreen({super.key, required this.appointment, this.cardToken});

  final Map<String, dynamic> appointment;
  final String? cardToken;

  @override
  State<RescheduleScreen> createState() => _RescheduleScreenState();
}

class _RescheduleScreenState extends State<RescheduleScreen> {
  final _api = MedThruApi.instance;
  late Future<List<Map<String, dynamic>>> _suggestions;

  bool _manualPickerOpen = false;
  DateTime _date = _today();
  Future<List<String>>? _manualSlots;
  String? _manualSlot;

  bool _submitting = false;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  String get _dateStr =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  int get _appointmentId => widget.appointment['id'] as int;
  int get _clinicId => widget.appointment['clinic_id'] as int;
  int? get _doctorId => widget.appointment['doctor_id'] as int?;

  @override
  void initState() {
    super.initState();
    _suggestions = _api.getRescheduleSuggestions(_appointmentId, cardToken: widget.cardToken);
    _suggestions.ignore();
  }

  void _openManualPicker() {
    setState(() {
      _manualPickerOpen = true;
      _manualSlots = _api.getAvailability(_clinicId, _dateStr, doctorId: _doctorId);
      _manualSlots!.ignore();
    });
  }

  Future<void> _pickManualDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today(),
      lastDate: _today().add(const Duration(days: 90)),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _manualSlot = null;
        _manualSlots = _api.getAvailability(_clinicId, _dateStr, doctorId: _doctorId);
        _manualSlots!.ignore();
      });
    }
  }

  Future<void> _propose(String startsAt) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await _api.proposeReschedule(
        _appointmentId,
        startsAt,
        cardToken: widget.cardToken,
      );
      if (!mounted) return;
      Navigator.pop(context, updated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reschedule appointment')),
      body: BoundedBody(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Currently at ${formatAppointmentTime(widget.appointment['starts_at'] as String)}.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('Suggested times',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
            const SizedBox(height: 10),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _suggestions,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Text(snap.error.toString().replaceFirst('Exception: ', ''),
                      style: TextStyle(color: scheme.error));
                }
                final suggestions = snap.data ?? const [];
                if (suggestions.isEmpty) {
                  return Text('No suggested times right now — pick one manually below.',
                      style: TextStyle(color: scheme.onSurfaceVariant));
                }
                return Column(
                  children: [
                    for (final s in suggestions)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          title: Text(formatAppointmentTime(s['startsAt'] as String)),
                          subtitle: Text(s['rationale'] as String),
                          trailing: FilledButton(
                            onPressed: _submitting ? null : () => _propose(s['startsAt'] as String),
                            child: const Text('Choose'),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            if (!_manualPickerOpen)
              OutlinedButton.icon(
                onPressed: _openManualPicker,
                icon: const Icon(Icons.edit_calendar_outlined),
                label: const Text('Pick a different time manually'),
              )
            else ...[
              Text('Pick a time manually',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pickManualDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(formatAppointmentTime('$_dateStr 00:00').split(',').first),
              ),
              const SizedBox(height: 12),
              SlotGrid(
                slots: _manualSlots!,
                selected: _manualSlot,
                onSelect: (s) => setState(() => _manualSlot = s),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (_manualSlot == null || _submitting)
                    ? null
                    : () => _propose('$_dateStr $_manualSlot'),
                icon: _submitting
                    ? const SizedBox(
                        height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.event_available),
                label: Text(_submitting ? 'Proposing…' : 'Propose this time'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: TextStyle(color: scheme.error))),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'The other side needs to accept this before it takes effect. '
              'Your current time is held until then.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
