import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// A patient editing their own identity — name and date of birth. Reached
/// with their card (or phone session); clinical fields stay doctor-only.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.token, required this.patient});
  final String token;
  final Map<String, dynamic> patient;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.patient['full_name'] as String? ?? '');
  late DateTime? _dob =
      DateTime.tryParse(widget.patient['date_of_birth'] as String? ?? '');
  // Optional demographic; feeds the doctor dashboard. Normalised to the two
  // values the dashboard buckets on, or null for "prefer not to say".
  late String? _gender = _normalizeGender(widget.patient['gender'] as String?);
  bool _saving = false;
  String? _error;

  static String? _normalizeGender(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'female':
      case 'f':
        return 'female';
      case 'male':
      case 'm':
        return 'male';
      default:
        return null;
    }
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name cannot be blank.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await MedThruApi.instance.updateMyProfile(
        widget.token,
        fullName: _name.text.trim(),
        dateOfBirth: _dob != null ? _fmt(_dob!) : '',
        // Empty string clears it server-side (optionalText -> null).
        gender: _gender ?? '',
      );
      if (!mounted) return;
      Navigator.pop(context, updated);
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
      appBar: AppBar(title: const Text('Edit profile')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Full name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.cake_outlined),
              label: Text(_dob != null ? _fmt(_dob!) : 'Date of birth (optional)'),
            ),
            const SizedBox(height: 16),
            Text('Gender (optional)',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Female'),
                  selected: _gender == 'female',
                  onSelected: (_) => setState(
                      () => _gender = _gender == 'female' ? null : 'female'),
                ),
                ChoiceChip(
                  label: const Text('Male'),
                  selected: _gender == 'male',
                  onSelected: (_) =>
                      setState(() => _gender = _gender == 'male' ? null : 'male'),
                ),
              ],
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
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
