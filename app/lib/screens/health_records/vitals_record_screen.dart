import 'package:flutter/material.dart';
import '../../api.dart';
import '../../health_record_widgets.dart';
import '../../readings.dart';
import '../../theme.dart';
import '../../widgets.dart';
import 'add_reading_screen.dart';

/// Vital signs or Anthropometry: a dedicated page for one reading category,
/// with a FAB to log another measurement scoped to that category.
class VitalsRecordScreen extends StatefulWidget {
  const VitalsRecordScreen({
    super.key,
    required this.patientId,
    required this.cardToken,
    required this.category,
    required this.title,
    required this.emptyLabel,
    required this.initialType,
  });

  final int patientId;

  /// Null when reached from the doctor directory without a card present —
  /// the page stays read-only: no add, no delete.
  final String? cardToken;
  final ReadingCategory category;
  final String title;
  final String emptyLabel;
  final String initialType;

  @override
  State<VitalsRecordScreen> createState() => _VitalsRecordScreenState();
}

class _VitalsRecordScreenState extends State<VitalsRecordScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getReadings(widget.patientId);
    _future.ignore();
  }

  Future<void> _add() async {
    final token = widget.cardToken;
    if (token == null) return;
    final reading = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddReadingScreen(
          token: token,
          initialType: widget.initialType,
          category: widget.category,
        ),
      ),
    );
    if (reading != null && mounted) {
      setState(_load);
    }
  }

  Future<void> _deleteReading(int id) async {
    final token = widget.cardToken;
    if (token == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete reading?'),
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
    if (confirmed != true || !mounted) return;

    try {
      await MedThruApi.instance.deleteReading(token, id);
      if (!mounted) return;
      setState(_load);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: BoundedBody(
        maxWidth: 640,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return CenteredMessage(
                icon: Icons.error_outline,
                title: 'Could not load',
                subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
              );
            }
            final rows = (snap.data ?? [])
                .where((r) => readingTypes[r['reading_type']]?.category == widget.category)
                .toList();
            if (rows.isEmpty) {
              return CenteredMessage(
                icon: Icons.monitor_heart_outlined,
                title: widget.emptyLabel,
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                ReadingCategoryBody(
                  rows: rows,
                  category: widget.category,
                  onDeleteRow: widget.cardToken == null ? null : _deleteReading,
                ),
                const SizedBox(height: 8),
                Text(
                  'Self-reported entries are informational only and are not a '
                  'diagnosis. They do not alter the clinical record.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: widget.cardToken == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }
}
