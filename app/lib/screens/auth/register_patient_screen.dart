import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';
import '../patient/patient_screen.dart';

/// Doctor-only: create a new patient record and bind it to a card token.
/// The token here will eventually be filled by tapping a blank card on the
/// ACR122U; for now it's typed in.
class RegisterPatientScreen extends StatefulWidget {
  const RegisterPatientScreen({super.key});

  @override
  State<RegisterPatientScreen> createState() => _RegisterPatientScreenState();
}

class _RegisterPatientScreenState extends State<RegisterPatientScreen> {
  final _fields = <String, TextEditingController>{
    'full_name': TextEditingController(),
    'date_of_birth': TextEditingController(),
    'blood_type': TextEditingController(),
    'allergies': TextEditingController(),
    'medications': TextEditingController(),
    'conditions': TextEditingController(),
    'emergency_contact_name': TextEditingController(),
    'emergency_contact_phone': TextEditingController(),
  };

  static const _labels = {
    'full_name': 'Full name *',
    'date_of_birth': 'Date of birth (YYYY-MM-DD)',
    'blood_type': 'Blood type',
    'allergies': 'Allergies',
    'medications': 'Medications',
    'conditions': 'Conditions',
    'emergency_contact_name': 'Emergency contact name',
    'emergency_contact_phone': 'Emergency contact phone',
  };

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _fields['full_name']!.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Full name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final data = {
        for (final entry in _fields.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
      };
      final result = await MedThruApi.instance.createPatient(data);
      if (!mounted) return;

      // The raw token exists only in this response — show it before anything
      // can navigate away.
      await showCardTokenDialog(
        context,
        token: result.cardToken,
        patientName: result.patient['full_name'] as String,
      );
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PatientScreen(
            patient: result.patient,
            cardToken: result.cardToken,
          ),
        ),
      );
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
      appBar: AppBar(title: const Text('Register new patient')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'A secure card token is generated automatically and shown once, '
              'so you can write it to a blank card. Fields marked * are required.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final entry in _labels.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextField(
                  controller: _fields[entry.key],
                  decoration: InputDecoration(
                    labelText: entry.value,
                    prefixIcon: entry.key == 'full_name'
                        ? const Icon(Icons.person_outline)
                        : null,
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt),
              label: Text(_saving ? 'Registering…' : 'Register patient'),
            ),
          ],
        ),
      ),
    );
  }
}
