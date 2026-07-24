import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// Book an appointment in advance at a registered hospital or clinic.
///
/// Open to patients: card possession is the credential, so no doctor login is
/// needed — matching how readings work. The flow is pick a facility, a date,
/// then one of the slots the server says is free. The booking is submitted as
/// a request and waits for a doctor to confirm it.
class BookAppointmentScreen extends StatefulWidget {
  const BookAppointmentScreen({super.key, required this.cardToken});

  /// Proves card possession; never rendered.
  final String cardToken;

  @override
  State<BookAppointmentScreen> createState() => _BookAppointmentScreenState();
}

const _reasonPresets = [
  'General checkup',
  'Dental checkup',
  'Follow-up',
  'Vaccination',
  'Lab test',
  'Consultation',
  'Other',
];

class _BookAppointmentScreenState extends State<BookAppointmentScreen> {
  final _api = MedThruApi.instance;
  final _reason = TextEditingController();
  String? _reasonPreset;

  late Future<List<Map<String, dynamic>>> _clinics;
  Map<String, dynamic>? _clinic;
  DateTime _date = _today();

  Future<List<String>>? _slots;
  String? _slot;
  bool _booking = false;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _clinics = _api.getClinics();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  String get _dateStr =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  void _selectClinic(Map<String, dynamic>? clinic) {
    setState(() {
      _clinic = clinic;
      _slot = null;
      _error = null;
      _loadSlots();
    });
  }

  void _loadSlots() {
    if (_clinic == null) {
      _slots = null;
      return;
    }
    _slots = _api.getAvailability(_clinic!['id'] as int, _dateStr);
    _slots!.ignore(); // handled by the FutureBuilder; silence unawaited-error
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today(),
      lastDate: _today().add(const Duration(days: 90)),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _slot = null;
        _error = null;
        _loadSlots();
      });
    }
  }

  bool get _reasonValid => _reason.text.trim().isNotEmpty;

  Future<void> _book() async {
    if (_clinic == null || _slot == null || !_reasonValid) return;
    setState(() {
      _booking = true;
      _error = null;
    });
    try {
      final appt = await _api.bookAppointment(
        widget.cardToken,
        clinicId: _clinic!['id'] as int,
        startsAt: '$_dateStr $_slot',
        reason: _reason.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, appt);
    } catch (e) {
      // A 409 (slot just taken) is worth reloading the grid so the patient
      // sees the true remaining slots rather than the stale one they tapped.
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _slot = null;
        _loadSlots();
      });
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Book appointment')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _StepLabel(n: 1, text: 'Choose a hospital or clinic'),
            const SizedBox(height: 10),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _clinics,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Text(
                    snap.error.toString().replaceFirst('Exception: ', ''),
                    style: TextStyle(color: scheme.error),
                  );
                }
                final clinics = snap.data ?? const [];
                if (clinics.isEmpty) {
                  return Text('No registered facilities yet.',
                      style: TextStyle(color: scheme.onSurfaceVariant));
                }
                return Column(
                  children: [
                    for (final c in clinics)
                      _ClinicOption(
                        clinic: c,
                        selected: _clinic?['id'] == c['id'],
                        onTap: () => _selectClinic(c),
                      ),
                  ],
                );
              },
            ),

            if (_clinic != null) ...[
              const SizedBox(height: 24),
              _StepLabel(n: 2, text: 'Pick a date'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(formatAppointmentTime('$_dateStr 00:00')
                    .split(',')
                    .first),
              ),
              const SizedBox(height: 24),
              _StepLabel(n: 3, text: 'Pick a time'),
              const SizedBox(height: 10),
              _SlotGrid(
                slots: _slots!,
                selected: _slot,
                onSelect: (s) => setState(() {
                  _slot = s;
                  _error = null;
                }),
              ),
              const SizedBox(height: 24),
              _StepLabel(n: 4, text: 'Reason for visit'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in _reasonPresets)
                    ChoiceChip(
                      label: Text(preset),
                      selected: _reasonPreset == preset,
                      onSelected: (selected) => setState(() {
                        _reasonPreset = selected ? preset : null;
                        // "Other" hands off to free text instead of prefilling it.
                        _reason.text =
                            selected && preset != 'Other' ? preset : '';
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                maxLines: 2,
                onChanged: (text) {
                  if (_reasonPreset != null &&
                      _reasonPreset != 'Other' &&
                      text != _reasonPreset) {
                    _reasonPreset = null;
                  }
                  setState(() {});
                },
                decoration: InputDecoration(
                  labelText: _reasonPreset == 'Other'
                      ? 'Please specify'
                      : 'Details',
                  hintText: 'e.g. Follow-up on blood sugar',
                  alignLabelWithHint: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(color: scheme.error)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed:
                    (_slot == null || _booking || !_reasonValid) ? null : _book,
                icon: _booking
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.event_available),
                label: Text(_booking ? 'Requesting…' : 'Request appointment'),
              ),
              const SizedBox(height: 12),
              Text(
                'Your request is sent to the clinic and holds this slot until a '
                'doctor confirms it. You can cancel it any time before then.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  const _StepLabel({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: scheme.primary,
          child: Text('$n',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Text(text,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
      ],
    );
  }
}

class _ClinicOption extends StatelessWidget {
  const _ClinicOption({
    required this.clinic,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> clinic;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHospital = clinic['kind'] == 'hospital';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          isHospital
              ? Icons.local_hospital_outlined
              : Icons.medical_services_outlined,
          color: scheme.primary,
        ),
        title: Text(clinic['name'] as String,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${(clinic['kind'] as String)[0].toUpperCase()}'
          '${(clinic['kind'] as String).substring(1)} · '
          '${clinic['opens_at']}–${clinic['closes_at']}'
          '${clinic['address'] != null ? '\n${clinic['address']}' : ''}',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        isThreeLine: clinic['address'] != null,
        trailing: selected
            ? Icon(Icons.check_circle, color: scheme.primary)
            : const Icon(Icons.circle_outlined, color: Colors.transparent),
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.slots,
    required this.selected,
    required this.onSelect,
  });

  final Future<List<String>> slots;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: slots,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(snap.error.toString().replaceFirst('Exception: ', ''),
              style: TextStyle(color: scheme.error));
        }
        final times = snap.data ?? const [];
        if (times.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'No open slots on this day. Try another date.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in times)
              ChoiceChip(
                label: Text(t),
                selected: selected == t,
                onSelected: (_) => onSelect(t),
              ),
          ],
        );
      },
    );
  }
}
