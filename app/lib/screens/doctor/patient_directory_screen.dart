import 'dart:async';
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';
import 'patient_summary_screen.dart';

/// Doctor-only directory of every registered patient, searchable by name.
/// Exists for the case a doctor needs a record without the card in hand —
/// unlike the rest of the app, nothing here depends on a card token.
class PatientDirectoryScreen extends StatefulWidget {
  const PatientDirectoryScreen({super.key});

  @override
  State<PatientDirectoryScreen> createState() => _PatientDirectoryScreenState();
}

class _PatientDirectoryScreenState extends State<PatientDirectoryScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      _future = MedThruApi.instance.getAllPatients(search: _search.text.trim());
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Patients')),
      body: BoundedBody(
        maxWidth: 640,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search by name',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            _load();
                          },
                        ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return CenteredMessage(
                      icon: Icons.error_outline,
                      title: 'Could not load patients',
                      subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
                    );
                  }
                  final patients = snap.data ?? [];
                  if (patients.isEmpty) {
                    return CenteredMessage(
                      icon: Icons.people_outline,
                      title: _search.text.isEmpty
                          ? 'No patients registered yet.'
                          : 'No patients match "${_search.text}".',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: patients.length,
                    itemBuilder: (context, i) {
                      final p = patients[i];
                      final cardStatus = p['card_status'] as String?;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PatientSummaryScreen(
                                patientId: p['id'] as int,
                                patientName: p['full_name'] as String,
                              ),
                            ),
                          ),
                          leading: CircleAvatar(
                            backgroundColor: scheme.primaryContainer,
                            child: Text(
                              (p['full_name'] as String).isNotEmpty
                                  ? (p['full_name'] as String)[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          title: Text(p['full_name'] as String,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [
                              if (p['blood_type'] != null) p['blood_type'] as String,
                              if (p['date_of_birth'] != null) p['date_of_birth'] as String,
                            ].join(' · '),
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                          ),
                          trailing: cardStatus == 'active'
                              ? Icon(Icons.credit_card, size: 18, color: scheme.primary)
                              : Icon(Icons.credit_card_off_outlined,
                                  size: 18, color: scheme.onSurfaceVariant),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
