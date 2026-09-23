import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api.dart';
import '../../contraindication_dialogs.dart';
import '../../notifications.dart';
import '../../widgets.dart';

/// Local-only reminder preference, keyed by medication id — see
/// `notifications.dart` for why this never touches the server.
String _reminderPrefKey(int medicationId) => 'med_reminder_$medicationId';

/// Log a medication. Open to patients (card possession is the credential).
class AddMedicationScreen extends StatefulWidget {
  const AddMedicationScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddMedicationScreen> createState() => _AddMedicationScreenState();
}

class _AddMedicationScreenState extends State<AddMedicationScreen> {
  late final _name = TextEditingController(text: widget.existing?['name'] as String? ?? '');
  late final _dosage = TextEditingController(text: widget.existing?['dosage'] as String? ?? '');
  late final _frequency =
      TextEditingController(text: widget.existing?['frequency'] as String? ?? '');
  late final _note = TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late DateTime? _startDate = DateTime.tryParse(widget.existing?['start_date'] as String? ?? '');
  late DateTime? _endDate = DateTime.tryParse(widget.existing?['end_date'] as String? ?? '');
  bool _saving = false;
  bool _checkingInteractions = false;
  String? _error;

  bool _reminderOn = false;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 9, minute: 0);

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _loadReminderPref();
  }

  Future<void> _loadReminderPref() async {
    final id = widget.existing?['id'] as int?;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_reminderPrefKey(id));
    if (saved == null || !mounted) return;
    final parts = saved.split(':');
    setState(() {
      _reminderOn = true;
      _reminderTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    });
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(context: context, initialTime: _reminderTime);
    if (picked != null) setState(() => _reminderTime = picked);
  }

  /// Schedules or cancels the on-device reminder to match `_reminderOn`,
  /// and remembers the choice locally so it survives an app restart.
  Future<void> _applyReminder(int medicationId) async {
    final prefs = await SharedPreferences.getInstance();
    if (_reminderOn) {
      await NotificationService.instance.scheduleMedicationReminder(
        medicationId: medicationId,
        name: _name.text.trim(),
        dosage: _dosage.text.trim(),
        hour: _reminderTime.hour,
        minute: _reminderTime.minute,
      );
      await prefs.setString(
        _reminderPrefKey(medicationId),
        '${_reminderTime.hour}:${_reminderTime.minute}',
      );
    } else {
      await NotificationService.instance.cancelMedicationReminder(medicationId);
      await prefs.remove(_reminderPrefKey(medicationId));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    _frequency.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
    }
  }

  /// Doctor-only pre-check: cross-references this medication against the
  /// patient's logged allergies and active medications before it's saved.
  /// `(proceed: false, ...)` means the doctor cancelled out of a warning.
  /// `overrideReason` is set when a hard stop was accepted with a typed
  /// reason — passed straight into the save/update call, which is what
  /// actually enforces and audits the override now, not this pre-check.
  Future<({bool proceed, String? overrideReason})> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'medication',
      treatmentName: _name.text.trim(),
      dosage: _dosage.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return (proceed: false, overrideReason: null);
      return (proceed: true, overrideReason: reason);
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final proceed = await showAiWarningDialog(context, aiFlag: aiFlag);
      return (proceed: proceed, overrideReason: null);
    }
    return (proceed: true, overrideReason: null);
  }

  Future<Map<String, dynamic>> _saveEntry(String? overrideReason) {
    return _isEdit
        ? MedThruApi.instance.updateMedication(
            widget.token,
            widget.existing!['id'] as int,
            name: _name.text.trim(),
            dosage: _dosage.text.trim(),
            frequency: _frequency.text.trim(),
            startDate: _startDate != null ? _fmt(_startDate!) : null,
            endDate: _endDate != null ? _fmt(_endDate!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          )
        : MedThruApi.instance.addMedication(
            widget.token,
            name: _name.text.trim(),
            dosage: _dosage.text.trim(),
            frequency: _frequency.text.trim(),
            startDate: _startDate != null ? _fmt(_startDate!) : null,
            endDate: _endDate != null ? _fmt(_endDate!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          );
  }

  /// Attempts the actual create/update call. If the server rejects it with
  /// a fresh hard stop the doctor never saw — the check-time and save-time
  /// states diverged, e.g. someone else just logged a new allergy — shows
  /// the same override dialog once and retries with the collected reason.
  /// Returns null if the doctor cancels out of that retry dialog.
  Future<Map<String, dynamic>?> _saveWithRetry(String? overrideReason) async {
    try {
      return await _saveEntry(overrideReason);
    } on ContraindicationBlockedException catch (blocked) {
      if (!mounted) return null;
      final reason = await showHardStopOverrideDialog(context, hardStops: blocked.hardStops);
      if (reason == null || !mounted) return null;
      return _saveEntry(reason);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter the medication name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? overrideReason;
      if (MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        ({bool proceed, String? overrideReason}) checkResult;
        try {
          checkResult = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!checkResult.proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        overrideReason = checkResult.overrideReason;
      }
      final entry = await _saveWithRetry(overrideReason);
      if (entry == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      await _applyReminder(entry['id'] as int);
      if (!mounted) return;
      Navigator.pop(context, entry);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit medication' : 'Add medication')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Medication name',
                hintText: 'e.g. Azithromycin',
                prefixIcon: Icon(Icons.medication_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dosage,
              decoration: const InputDecoration(
                labelText: 'Dosage (optional)',
                hintText: 'e.g. 500mg',
                prefixIcon: Icon(Icons.science_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _frequency,
              decoration: const InputDecoration(
                labelText: 'Frequency (optional)',
                hintText: 'e.g. Once daily',
                prefixIcon: Icon(Icons.repeat),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _reminderOn,
              onChanged: (v) => setState(() => _reminderOn = v),
              title: const Text('Remind me to take this'),
              subtitle: Text(
                _reminderOn
                    ? 'Daily at ${_reminderTime.format(context)}'
                    : 'A daily notification on this device',
              ),
              secondary: const Icon(Icons.notifications_outlined),
            ),
            if (_reminderOn)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _pickReminderTime,
                  icon: const Icon(Icons.access_time),
                  label: Text('Change time (${_reminderTime.format(context)})'),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isStart: true),
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: Text(_startDate != null ? _fmt(_startDate!) : 'Start date'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isStart: false),
                    icon: const Icon(Icons.event_busy_outlined),
                    label: Text(_endDate != null ? _fmt(_endDate!) : 'End date'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_isEdit ? Icons.save_outlined : Icons.add),
              label: Text(
                _checkingInteractions
                    ? 'Checking interactions…'
                    : (_saving ? 'Saving…' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
