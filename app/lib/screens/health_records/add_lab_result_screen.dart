import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

const labResultStatuses = ['Normal', 'High', 'Low', 'Critical'];

/// Log a lab / test result. Open to patients (card possession is the
/// credential); a doctor viewing the card can add one too.
class AddLabResultScreen extends StatefulWidget {
  const AddLabResultScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddLabResultScreen> createState() => _AddLabResultScreenState();
}

class _AddLabResultScreenState extends State<AddLabResultScreen> {
  late final _testName =
      TextEditingController(text: widget.existing?['test_name'] as String? ?? '');
  late final _value =
      TextEditingController(text: widget.existing?['value'] as String? ?? '');
  late final _unit =
      TextEditingController(text: widget.existing?['unit'] as String? ?? '');
  late final _range =
      TextEditingController(text: widget.existing?['reference_range'] as String? ?? '');
  late final _note =
      TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late DateTime? _takenAt =
      DateTime.tryParse(widget.existing?['taken_at'] as String? ?? '');
  late String _status = switch ((widget.existing?['status'] as String?)?.toLowerCase()) {
    'high' => 'High',
    'low' => 'Low',
    'critical' => 'Critical',
    _ => 'Normal',
  };
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _testName.dispose();
    _value.dispose();
    _unit.dispose();
    _range.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _takenAt ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _takenAt = picked);
  }

  Future<void> _save() async {
    if (_testName.text.trim().isEmpty) {
      setState(() => _error = 'Enter the test name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = _isEdit
          ? await MedThruApi.instance.updateLabResult(
              widget.token,
              widget.existing!['id'] as int,
              testName: _testName.text.trim(),
              value: _value.text.trim(),
              unit: _unit.text.trim(),
              referenceRange: _range.text.trim(),
              status: _status.toLowerCase(),
              takenAt: _takenAt != null ? _fmt(_takenAt!) : null,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addLabResult(
              widget.token,
              testName: _testName.text.trim(),
              value: _value.text.trim(),
              unit: _unit.text.trim(),
              referenceRange: _range.text.trim(),
              status: _status.toLowerCase(),
              takenAt: _takenAt != null ? _fmt(_takenAt!) : null,
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit lab result' : 'Add lab result')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _testName,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Test',
                hintText: 'e.g. HbA1c, LDL cholesterol',
                prefixIcon: Icon(Icons.science_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _value,
                    decoration: const InputDecoration(
                      labelText: 'Result',
                      hintText: 'e.g. 6.1',
                      prefixIcon: Icon(Icons.numbers_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      hintText: 'e.g. %, mmol/L',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _range,
              decoration: const InputDecoration(
                labelText: 'Reference range (optional)',
                hintText: 'e.g. 4.0–5.6',
                prefixIcon: Icon(Icons.straighten_outlined),
              ),
            ),
            const SizedBox(height: 16),
            Text('Status',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final s in labResultStatuses)
                  ChoiceChip(
                    label: Text(s),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(_takenAt != null
                  ? 'Taken ${_fmt(_takenAt!)}'
                  : 'Date taken (optional)'),
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
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
