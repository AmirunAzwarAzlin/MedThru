import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

const severityLevels = ['Mild', 'Moderate', 'Severe'];

/// Log an allergy or intolerance. Open to patients (card possession is the
/// credential), like readings — a doctor viewing the card can add one too.
class AddAllergyScreen extends StatefulWidget {
  const AddAllergyScreen({super.key, required this.token, this.existing});
  final String token;

  /// When set, the screen edits this entry instead of creating a new one.
  final Map<String, dynamic>? existing;

  @override
  State<AddAllergyScreen> createState() => _AddAllergyScreenState();
}

class _AddAllergyScreenState extends State<AddAllergyScreen> {
  late final _allergen =
      TextEditingController(text: widget.existing?['allergen'] as String? ?? '');
  late final _reaction =
      TextEditingController(text: widget.existing?['reaction'] as String? ?? '');
  late final _note = TextEditingController(text: widget.existing?['note'] as String? ?? '');
  late String? _severity = widget.existing?['severity'] as String?;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _allergen.dispose();
    _reaction.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_allergen.text.trim().isEmpty) {
      setState(() => _error = 'Enter what the allergy or intolerance is to.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = _isEdit
          ? await MedThruApi.instance.updateAllergy(
              widget.token,
              widget.existing!['id'] as int,
              allergen: _allergen.text.trim(),
              reaction: _reaction.text.trim(),
              severity: _severity,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addAllergy(
              widget.token,
              allergen: _allergen.text.trim(),
              reaction: _reaction.text.trim(),
              severity: _severity,
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
      appBar: AppBar(
          title: Text(_isEdit ? 'Edit allergy / intolerance' : 'Add allergy / intolerance')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _allergen,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Allergen',
                hintText: 'e.g. Penicillin, peanuts, shellfish',
                prefixIcon: Icon(Icons.warning_amber_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reaction,
              decoration: const InputDecoration(
                labelText: 'Reaction (optional)',
                hintText: 'e.g. Rash, swelling, anaphylaxis',
                prefixIcon: Icon(Icons.healing_outlined),
              ),
            ),
            const SizedBox(height: 16),
            Text('Severity (optional)',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final level in severityLevels)
                  ChoiceChip(
                    label: Text(level),
                    selected: _severity == level,
                    onSelected: (selected) =>
                        setState(() => _severity = selected ? level : null),
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
