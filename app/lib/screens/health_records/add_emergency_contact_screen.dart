import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

const relationshipOptions = ['Spouse', 'Parent', 'Child', 'Sibling', 'Friend', 'Other'];

/// Add or edit an emergency contact. Open to patients (card possession is
/// the credential) — a doctor viewing the card can add one too.
class AddEmergencyContactScreen extends StatefulWidget {
  const AddEmergencyContactScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddEmergencyContactScreen> createState() => _AddEmergencyContactScreenState();
}

class _AddEmergencyContactScreenState extends State<AddEmergencyContactScreen> {
  late final _name = TextEditingController(text: widget.existing?['name'] as String? ?? '');
  late final _phone = TextEditingController(text: widget.existing?['phone'] as String? ?? '');
  late final _note = TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late String? _relationship = widget.existing?['relationship'] as String?;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter the contact\'s name.');
      return;
    }
    if (_phone.text.trim().isEmpty) {
      setState(() => _error = 'Enter a phone number.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = _isEdit
          ? await MedThruApi.instance.updateEmergencyContact(
              widget.token,
              widget.existing!['id'] as int,
              name: _name.text.trim(),
              phone: _phone.text.trim(),
              relationship: _relationship,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addEmergencyContact(
              widget.token,
              name: _name.text.trim(),
              phone: _phone.text.trim(),
              relationship: _relationship,
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit emergency contact' : 'Add emergency contact')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 16),
            Text('Relationship (optional)',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in relationshipOptions)
                  ChoiceChip(
                    label: Text(r),
                    selected: _relationship == r,
                    onSelected: (selected) =>
                        setState(() => _relationship = selected ? r : null),
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
