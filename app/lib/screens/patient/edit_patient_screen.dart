import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

class EditPatientScreen extends StatefulWidget {
  const EditPatientScreen({
    super.key,
    required this.patient,
    required this.cardToken,
  });
  final Map<String, dynamic> patient;
  final String cardToken;

  @override
  State<EditPatientScreen> createState() => _EditPatientScreenState();
}

class _EditPatientScreenState extends State<EditPatientScreen> {
  late final Map<String, TextEditingController> _controllers;
  bool _saving = false;
  String? _error;

  static const _editableFields = {
    'blood_type': 'Blood type',
    'allergies': 'Allergies',
    'medications': 'Medications',
    'conditions': 'Conditions',
    'primary_doctor': 'Primary doctor',
    'next_appointment': 'Next appointment (YYYY-MM-DD)',
    'surgery_date': 'Surgery date (YYYY-MM-DD)',
    'emergency_contact_name': 'Emergency contact name',
    'emergency_contact_phone': 'Emergency contact phone',
  };

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final key in _editableFields.keys)
        key: TextEditingController(text: widget.patient[key]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final fields = {
        for (final entry in _controllers.entries) entry.key: entry.value.text,
      };
      final updated =
          await MedThruApi.instance.updatePatient(widget.cardToken, fields);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Record updated')),
      );
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
      appBar: AppBar(title: const Text('Edit record')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            for (final entry in _editableFields.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextField(
                  controller: _controllers[entry.key],
                  decoration: InputDecoration(labelText: entry.value),
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
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving…' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
