import 'package:flutter/material.dart';
import '../../api.dart';
import '../../contraindication_dialogs.dart';
import '../../widgets.dart';

/// Log a vaccination. Open to patients (card possession is the credential).
class AddVaccinationScreen extends StatefulWidget {
  const AddVaccinationScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddVaccinationScreen> createState() => _AddVaccinationScreenState();
}

class _AddVaccinationScreenState extends State<AddVaccinationScreen> {
  late final _vaccine = TextEditingController(text: widget.existing?['vaccine'] as String? ?? '');
  late final _doseNumber =
      TextEditingController(text: widget.existing?['dose_number']?.toString() ?? '');
  late final _note = TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late DateTime _administeredAt =
      DateTime.tryParse(widget.existing?['administered_at'] as String? ?? '') ?? DateTime.now();
  late DateTime? _nextDue =
      DateTime.tryParse(widget.existing?['next_due'] as String? ?? '');
  bool _saving = false;
  bool _checkingInteractions = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _vaccine.dispose();
    _doseNumber.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _administeredAt,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _administeredAt = picked);
  }

  Future<void> _pickNextDue() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextDue ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _nextDue = picked);
  }

  /// Doctor-only pre-check: cross-references this vaccine against the
  /// patient's logged allergies and active medications before it's saved.
  /// Returns false if the doctor cancels out of a warning; true otherwise
  /// (including when nothing was flagged at all).
  Future<bool> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'vaccination',
      treatmentName: _vaccine.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return false;
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return false;
      await MedThruApi.instance.overrideContraindication(
        widget.token,
        ruleIds: hardStops.map((h) => h['ruleId'] as int).toList(),
        reason: reason,
        treatmentName: _vaccine.text.trim(),
      );
      return true;
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return false;
      return showAiWarningDialog(context, aiFlag: aiFlag);
    }
    return true;
  }

  Future<void> _save() async {
    if (_vaccine.text.trim().isEmpty) {
      setState(() => _error = 'Enter the vaccine name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_isEdit && MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        bool proceed;
        try {
          proceed = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
      }
      final entry = _isEdit
          ? await MedThruApi.instance.updateVaccination(
              widget.token,
              widget.existing!['id'] as int,
              vaccine: _vaccine.text.trim(),
              administeredAt: _fmt(_administeredAt),
              doseNumber: int.tryParse(_doseNumber.text.trim()),
              nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addVaccination(
              widget.token,
              vaccine: _vaccine.text.trim(),
              administeredAt: _fmt(_administeredAt),
              doseNumber: int.tryParse(_doseNumber.text.trim()),
              nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
              note: _note.text.trim(),
            );
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit vaccination' : 'Add vaccination')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _vaccine,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Vaccine',
                hintText: 'e.g. Influenza, Tetanus',
                prefixIcon: Icon(Icons.vaccines_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _doseNumber,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Dose number (optional)',
                hintText: 'e.g. 1',
                prefixIcon: Icon(Icons.tag_outlined),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text('Administered on ${_fmt(_administeredAt)}'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickNextDue,
              icon: const Icon(Icons.event_repeat_outlined),
              label: Text(_nextDue != null
                  ? 'Next dose due ${_fmt(_nextDue!)}'
                  : 'Next dose due (optional)'),
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
