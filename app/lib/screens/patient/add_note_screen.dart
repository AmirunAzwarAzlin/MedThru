import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// Note types shown to the doctor, mapped to the backend's enum values.
const noteTypes = <String, ({String label, IconData icon})>{
  'checkup': (label: 'Checkup', icon: Icons.monitor_heart_outlined),
  'medication_change': (label: 'Medication change', icon: Icons.medication),
  'surgery': (label: 'Surgery', icon: Icons.local_hospital_outlined),
  'appointment': (label: 'Appointment', icon: Icons.event_outlined),
  'lab_result': (label: 'Lab result', icon: Icons.science_outlined),
  'general': (label: 'General note', icon: Icons.note_outlined),
};

/// Doctor-only: add an entry to a patient's clinical-update timeline.
class AddNoteScreen extends StatefulWidget {
  const AddNoteScreen({super.key, required this.patientId});
  final int patientId;

  @override
  State<AddNoteScreen> createState() => _AddNoteScreenState();
}

class _AddNoteScreenState extends State<AddNoteScreen> {
  String _type = 'checkup';
  final _body = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_body.text.trim().isEmpty) {
      setState(() => _error = 'Write some details first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final note =
          await MedThruApi.instance.addNote(widget.patientId, _type, _body.text);
      if (!mounted) return;
      Navigator.pop(context, note); // return the new note to the caller
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
      appBar: AppBar(title: const Text('Add clinical update')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Update type',
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in noteTypes.entries)
                  ChoiceChip(
                    label: Text(entry.value.label),
                    avatar: Icon(entry.value.icon, size: 18),
                    selected: _type == entry.key,
                    onSelected: (_) => setState(() => _type = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _body,
              autofocus: true,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Details',
                hintText:
                    'e.g. BP 130/85, patient stable, continue current meds…',
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
                  : const Icon(Icons.add),
              label: Text(_saving ? 'Saving…' : 'Add update'),
            ),
          ],
        ),
      ),
    );
  }
}
