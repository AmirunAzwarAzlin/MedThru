import 'package:flutter/material.dart';
import '../../api.dart';
import '../../health_record_widgets.dart';
import '../../theme.dart';
import '../../widgets.dart';
import 'add_allergy_screen.dart';
import 'add_medication_screen.dart';
import 'add_vaccination_screen.dart';
import 'add_medical_history_screen.dart';
import 'add_emergency_contact_screen.dart';
import 'add_lab_result_screen.dart';

/// Wiring for one Health Records category: what to fetch, how a row renders,
/// which screen adds or edits an entry, and how to delete one. One screen
/// class below serves all four categories by swapping this out.
class HealthRecordCategoryConfig {
  const HealthRecordCategoryConfig({
    required this.title,
    required this.emptyLabel,
    required this.fetch,
    required this.itemBuilder,
    required this.addScreenBuilder,
    required this.editScreenBuilder,
    required this.delete,
  });

  final String title;
  final String emptyLabel;
  final Future<List<Map<String, dynamic>>> Function(int patientId) fetch;
  final Widget Function(Map<String, dynamic> row) itemBuilder;
  final Widget Function(String cardToken) addScreenBuilder;
  final Widget Function(String cardToken, Map<String, dynamic> row) editScreenBuilder;
  final Future<void> Function(String cardToken, int id) delete;
}

final allergyRecordConfig = HealthRecordCategoryConfig(
  title: 'Allergies & intolerances',
  emptyLabel: 'No allergies or intolerances logged.',
  fetch: (patientId) => MedThruApi.instance.getAllergiesForPatient(patientId),
  itemBuilder: (row) => AllergyCard(row: row),
  addScreenBuilder: (token) => AddAllergyScreen(token: token),
  editScreenBuilder: (token, row) => AddAllergyScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteAllergy(token, id),
);

final medicationRecordConfig = HealthRecordCategoryConfig(
  title: 'Medications',
  emptyLabel: 'No medications logged.',
  fetch: (patientId) => MedThruApi.instance.getMedicationsForPatient(patientId),
  itemBuilder: (row) => MedicationCard(row: row),
  addScreenBuilder: (token) => AddMedicationScreen(token: token),
  editScreenBuilder: (token, row) => AddMedicationScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteMedication(token, id),
);

final vaccinationRecordConfig = HealthRecordCategoryConfig(
  title: 'Vaccinations',
  emptyLabel: 'No vaccinations logged.',
  fetch: (patientId) => MedThruApi.instance.getVaccinationsForPatient(patientId),
  itemBuilder: (row) => VaccinationCard(row: row),
  addScreenBuilder: (token) => AddVaccinationScreen(token: token),
  editScreenBuilder: (token, row) => AddVaccinationScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteVaccination(token, id),
);

final medicalHistoryRecordConfig = HealthRecordCategoryConfig(
  title: 'Medical history',
  emptyLabel: 'No medical history logged.',
  fetch: (patientId) => MedThruApi.instance.getMedicalHistoryForPatient(patientId),
  itemBuilder: (row) => MedicalHistoryCard(row: row),
  addScreenBuilder: (token) => AddMedicalHistoryScreen(token: token),
  editScreenBuilder: (token, row) => AddMedicalHistoryScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteMedicalHistory(token, id),
);

final labResultRecordConfig = HealthRecordCategoryConfig(
  title: 'Lab results',
  emptyLabel: 'No lab or test results logged.',
  fetch: (patientId) => MedThruApi.instance.getLabResultsForPatient(patientId),
  itemBuilder: (row) => LabResultCard(row: row),
  addScreenBuilder: (token) => AddLabResultScreen(token: token),
  editScreenBuilder: (token, row) => AddLabResultScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteLabResult(token, id),
);

final emergencyContactRecordConfig = HealthRecordCategoryConfig(
  title: 'Emergency contacts',
  emptyLabel: 'No emergency contacts added yet.',
  fetch: (patientId) => MedThruApi.instance.getEmergencyContactsForPatient(patientId),
  itemBuilder: (row) => EmergencyContactCard(row: row),
  addScreenBuilder: (token) => AddEmergencyContactScreen(token: token),
  editScreenBuilder: (token, row) => AddEmergencyContactScreen(token: token, existing: row),
  delete: (token, id) => MedThruApi.instance.deleteEmergencyContact(token, id),
);

/// A dedicated page for one Health Records category: its list, a FAB to add
/// another entry, tap-to-edit on any row, and swipe-to-delete. Reused for
/// allergies, medications, vaccinations and medical history via [config].
class HealthRecordListScreen extends StatefulWidget {
  const HealthRecordListScreen({
    super.key,
    required this.patientId,
    required this.cardToken,
    required this.config,
  });

  final int patientId;

  /// Null when reached from the doctor directory without a card present —
  /// the list stays read-only: no add, no edit, no delete.
  final String? cardToken;
  final HealthRecordCategoryConfig config;

  @override
  State<HealthRecordListScreen> createState() => _HealthRecordListScreenState();
}

class _HealthRecordListScreenState extends State<HealthRecordListScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = widget.config.fetch(widget.patientId);
    _future.ignore();
  }

  Future<void> _add() async {
    final token = widget.cardToken;
    if (token == null) return;
    final entry = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => widget.config.addScreenBuilder(token)),
    );
    if (entry != null && mounted) {
      setState(_load);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final token = widget.cardToken;
    if (token == null) return;
    final entry = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => widget.config.editScreenBuilder(token, row),
      ),
    );
    if (entry != null && mounted) {
      setState(_load);
    }
  }

  Future<bool> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete entry?'),
        content: const Text('This removes it from the record. This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _delete(int id) async {
    final token = widget.cardToken;
    if (token == null) return;
    try {
      await widget.config.delete(token, id);
      if (!mounted) return;
      setState(_load);
    } catch (e) {
      if (!mounted) return;
      setState(_load); // the row survived; undo the optimistic swipe
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Widget _rowBuilder(Map<String, dynamic> row) {
    if (widget.cardToken == null) {
      return widget.config.itemBuilder(row);
    }
    return Dismissible(
      key: ValueKey(row['id']),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(),
      onDismissed: (_) => _delete(row['id'] as int),
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: MedThruTheme.danger,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _edit(row),
        child: widget.config.itemBuilder(row),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.cardToken == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              readOnly
                  ? 'Read-only — reached without the patient\'s card'
                  : 'Tap an entry to edit · swipe to delete',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
      body: BoundedBody(
        maxWidth: 640,
        child: RecordFutureList(
          future: _future,
          itemBuilder: _rowBuilder,
          emptyLabel: widget.config.emptyLabel,
        ),
      ),
      floatingActionButton: readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }
}
