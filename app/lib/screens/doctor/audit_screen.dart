import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// Doctor-only: full access history for a patient (every read and edit,
/// who did it and when).
class AuditScreen extends StatefulWidget {
  const AuditScreen({
    super.key,
    required this.patientId,
    required this.patientName,
  });

  final int patientId;
  final String patientName;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = MedThruApi.instance.getAudit(widget.patientId);
  }

  IconData _iconFor(String action) => switch (action) {
        'create' => Icons.add_circle_outline,
        'update' => Icons.edit_outlined,
        'read' => Icons.visibility_outlined,
        _ => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('History · ${widget.patientName}')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return CenteredMessage(
              icon: Icons.error_outline,
              title: 'Could not load history',
              subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
            );
          }
          final entries = snap.data ?? [];
          if (entries.isEmpty) {
            return const CenteredMessage(
              icon: Icons.history,
              title: 'No history yet',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final e = entries[i];
              final action = e['action'] as String;
              final who = e['doctor_name'] as String? ?? 'Card tap (patient)';
              final details = e['details'] as String?;
              return Card(
                child: ListTile(
                  leading: Icon(_iconFor(action), color: scheme.primary),
                  title: Text(
                    '${action[0].toUpperCase()}${action.substring(1)} · $who',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [?details, e['timestamp']].join('\n'),
                  ),
                  isThreeLine: details != null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
