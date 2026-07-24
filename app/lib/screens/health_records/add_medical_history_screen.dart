import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

const medicalHistoryStatuses = ['Active', 'Resolved'];

/// Log a past or ongoing diagnosis. Open to patients (card possession is the
/// credential); a doctor viewing the card can add one too.
class AddMedicalHistoryScreen extends StatefulWidget {
  const AddMedicalHistoryScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddMedicalHistoryScreen> createState() => _AddMedicalHistoryScreenState();
}

class _AddMedicalHistoryScreenState extends State<AddMedicalHistoryScreen> {
  late final _condition =
      TextEditingController(text: widget.existing?['condition_name'] as String? ?? '');
  late final _note = TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late DateTime? _diagnosedAt =
      DateTime.tryParse(widget.existing?['diagnosed_at'] as String? ?? '');
  late String _status = switch (widget.existing?['status'] as String?) {
    'resolved' => 'Resolved',
    _ => 'Active',
  };
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _condition.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _diagnosedAt ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _diagnosedAt = picked);
  }

  Future<void> _save() async {
    if (_condition.text.trim().isEmpty) {
      setState(() => _error = 'Enter the condition or diagnosis.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = _isEdit
          ? await MedThruApi.instance.updateMedicalHistory(
              widget.token,
              widget.existing!['id'] as int,
              conditionName: _condition.text.trim(),
              diagnosedAt: _diagnosedAt != null ? _fmt(_diagnosedAt!) : null,
              status: _status.toLowerCase(),
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addMedicalHistory(
              widget.token,
              conditionName: _condition.text.trim(),
              diagnosedAt: _diagnosedAt != null ? _fmt(_diagnosedAt!) : null,
              status: _status.toLowerCase(),
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit medical history' : 'Add medical history')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _condition,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Condition / diagnosis',
                hintText: 'e.g. Hypertension, Asthma',
                prefixIcon: Icon(Icons.monitor_heart_outlined),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(_diagnosedAt != null
                  ? 'Diagnosed ${_fmt(_diagnosedAt!)}'
                  : 'Diagnosed date (optional)'),
            ),
            const SizedBox(height: 16),
            Text('Status',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final s in medicalHistoryStatuses)
                  ChoiceChip(
                    label: Text(s),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
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
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
