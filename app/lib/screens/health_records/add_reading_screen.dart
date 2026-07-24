import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../api.dart';
import '../../readings.dart';
import '../../widgets.dart';

/// Log a self-measured reading. Open to patients (card possession is the
/// credential) — unlike the clinical record, which stays doctor-only.
class AddReadingScreen extends StatefulWidget {
  const AddReadingScreen({
    super.key,
    required this.token,
    this.initialType = 'blood_sugar',
    this.category,
  });

  final String token;
  final String initialType;

  /// Restricts the type picker to one Health Records section (vitals or
  /// anthropometry). Null shows every type, for the general "Add reading"
  /// entry point.
  final ReadingCategory? category;

  @override
  State<AddReadingScreen> createState() => _AddReadingScreenState();
}

class _AddReadingScreenState extends State<AddReadingScreen> {
  late String _type = widget.initialType;

  Iterable<ReadingType> get _types => widget.category == null
      ? readingTypes.values
      : readingTypes.values.where((t) => t.category == widget.category);
  final _value = TextEditingController();
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  ReadingType get _spec => readingTypes[_type]!;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final parsed = double.tryParse(_value.text.trim());
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Enter a valid number greater than 0.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final reading = await MedThruApi.instance
          .addReading(widget.token, _type, parsed, note: _note.text.trim());
      if (!mounted) return;
      Navigator.pop(context, reading);
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
      appBar: AppBar(title: const Text('Add reading')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('What did you measure?',
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in _types)
                  ChoiceChip(
                    label: Text(t.label),
                    avatar: Icon(t.icon, size: 18),
                    selected: _type == t.key,
                    onSelected: (_) => setState(() {
                      _type = t.key;
                      _error = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _value,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: 'Value',
                prefixIcon: Icon(_spec.icon),
                suffixText: _spec.unit,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_spec.typical,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _note,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. fasting, before breakfast',
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
              label: Text(_saving ? 'Saving…' : 'Save reading'),
            ),
            const SizedBox(height: 12),
            Text(
              'Readings you add are marked as self-reported. They do not '
              'change your medical record, and are not a diagnosis.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
