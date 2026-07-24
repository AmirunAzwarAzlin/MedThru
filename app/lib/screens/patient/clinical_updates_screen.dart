import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';
import 'add_note_screen.dart';

/// Clinical updates is a pushed screen, reached only from the Home dashboard
/// tile. Self-fetches and reloads its own notes, doctor-only add FAB.
class ClinicalUpdatesScreen extends StatefulWidget {
  const ClinicalUpdatesScreen({
    super.key,
    required this.patientId,
    required this.isDoctor,
  });
  final int patientId;
  final bool isDoctor;

  @override
  State<ClinicalUpdatesScreen> createState() => _ClinicalUpdatesScreenState();
}

class _ClinicalUpdatesScreenState extends State<ClinicalUpdatesScreen> {
  late Future<List<Map<String, dynamic>>> _notes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _notes = MedThruApi.instance.getNotes(widget.patientId);
    _notes.ignore();
  }

  Future<void> _addUpdate() async {
    final note = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddNoteScreen(patientId: widget.patientId),
      ),
    );
    if (note != null && mounted) {
      setState(_load);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clinical updates')),
      body: BoundedBody(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text(
              'Checkups, medication changes and other visit notes.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            _NotesTimeline(future: _notes),
          ],
        ),
      ),
      floatingActionButton: widget.isDoctor
          ? FloatingActionButton.extended(
              onPressed: _addUpdate,
              icon: const Icon(Icons.add),
              label: const Text('Add update'),
            )
          : null,
    );
  }
}

class _NotesTimeline extends StatelessWidget {
  const _NotesTimeline({required this.future});
  final Future<List<Map<String, dynamic>>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(
            'Could not load updates.',
            style: TextStyle(color: scheme.error),
          );
        }
        final notes = snap.data ?? [];
        if (notes.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(28),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(
                  Icons.timeline_outlined,
                  size: 44,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 10),
                Text(
                  'No clinical updates yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          );
        }
        return Column(children: [for (final n in notes) _NoteCard(note: n)]);
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});
  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = note['note_type'] as String;
    final meta = noteTypes[type];
    final label = meta?.label ?? type;
    final icon = meta?.icon ?? Icons.note_outlined;
    final who = note['doctor_name'] as String? ?? 'Unknown';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              Text(
                note['created_at']?.toString() ?? '',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            note['body']?.toString() ?? '',
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            '— $who',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
