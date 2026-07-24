import 'package:flutter/material.dart';
import '../../widgets.dart';
import 'edit_patient_screen.dart';

/// Care plan is a pushed screen, reached only from the Home dashboard tile —
/// it carries its own "Edit record" FAB now that it's not living inside the
/// shared tab bar's FAB switch.
class CarePlanScreen extends StatefulWidget {
  const CarePlanScreen({
    super.key,
    required this.patient,
    required this.cardToken,
    required this.isDoctor,
  });
  final Map<String, dynamic> patient;
  final String cardToken;
  final bool isDoctor;

  @override
  State<CarePlanScreen> createState() => _CarePlanScreenState();
}

class _CarePlanScreenState extends State<CarePlanScreen> {
  late Map<String, dynamic> _patient = widget.patient;

  String _val(String key) {
    final v = _patient[key];
    return (v == null || (v is String && v.isEmpty)) ? '—' : v.toString();
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            EditPatientScreen(patient: _patient, cardToken: widget.cardToken),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _patient = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Care plan')),
      body: BoundedBody(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            FieldCard(
              label: 'Primary doctor',
              value: _val('primary_doctor'),
              icon: Icons.person_outline,
            ),
            FieldCard(
              label: 'Next appointment',
              value: _val('next_appointment'),
              icon: Icons.event_available_outlined,
            ),
            FieldCard(
              label: 'Surgery date',
              value: _val('surgery_date'),
              icon: Icons.local_hospital_outlined,
            ),
            FieldCard(
              label: 'Current medications',
              value: _val('medications'),
              icon: Icons.medication_outlined,
            ),
          ],
        ),
      ),
      floatingActionButton: widget.isDoctor
          ? FloatingActionButton.extended(
              onPressed: _edit,
              icon: const Icon(Icons.edit),
              label: const Text('Edit record'),
            )
          : null,
    );
  }
}
