import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../health_record_widgets.dart' show SourcePill, whoFor, RecordFutureList;
import '../../theme.dart';
import '../../widgets.dart';

/// Best-guess MIME type from a file extension, so the server and the viewer
/// know how to handle it. Unknown types fall back to a generic binary.
String mimeForExtension(String? ext) {
  switch (ext?.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'heic':
      return 'image/heic';
    case 'pdf':
      return 'application/pdf';
    default:
      return 'application/octet-stream';
  }
}

String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

IconData _iconForMime(String? mime) {
  if (mime == null) return Icons.insert_drive_file_outlined;
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}

/// Uploaded documents for one patient: scans, referral letters, X-rays. Reuses
/// the same "reached without a card is read-only" rule as the other record
/// categories — no card means no upload and no delete.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({
    super.key,
    required this.patientId,
    required this.cardToken,
  });

  final int patientId;
  final String? cardToken;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getDocumentsForPatient(widget.patientId);
    _future.ignore();
  }

  Future<void> _upload() async {
    final token = widget.cardToken;
    if (token == null || _uploading) return;

    final picked = await FilePicker.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _snack('Could not read that file.');
      return;
    }

    setState(() => _uploading = true);
    try {
      await MedThruApi.instance.uploadDocument(
        token,
        filename: file.name,
        mimeType: mimeForExtension(file.extension),
        bytes: bytes,
      );
      if (!mounted) return;
      setState(_load);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<bool> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: const Text('This removes the file from the record. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep it')),
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
      await MedThruApi.instance.deleteDocument(token, id);
      if (!mounted) return;
      setState(_load);
    } catch (e) {
      if (!mounted) return;
      setState(_load);
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _rowBuilder(Map<String, dynamic> row) {
    final card = InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerScreen(patientId: widget.patientId, doc: row),
        ),
      ),
      child: DocumentCard(row: row),
    );
    if (widget.cardToken == null) return card;
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
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.cardToken == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              readOnly
                  ? 'Read-only — reached without the patient\'s card'
                  : 'Tap to view · swipe to delete',
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
          emptyLabel: 'No documents uploaded yet.',
        ),
      ),
      floatingActionButton: readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _uploading ? null : _upload,
              icon: _uploading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.upload_file_outlined),
              label: Text(_uploading ? 'Uploading…' : 'Upload'),
            ),
    );
  }
}

class DocumentCard extends StatelessWidget {
  const DocumentCard({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mime = row['mime_type'] as String?;
    final size = formatBytes((row['size_bytes'] as num?)?.toInt());
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: MedThruTheme.tileBlue,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_iconForMime(mime), color: MedThruTheme.iconBlue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row['filename'] as String? ?? 'Document',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                if (size.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(size, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 6),
                SourcePill(
                  bySelf: row['source'] == 'patient',
                  who: whoFor(row),
                  date: row['created_at']?.toString() ?? '',
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// Opens one document: images render inline; any type can be saved to disk.
class DocumentViewerScreen extends StatefulWidget {
  const DocumentViewerScreen({super.key, required this.patientId, required this.doc});
  final int patientId;
  final Map<String, dynamic> doc;

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = MedThruApi.instance
        .downloadDocument(widget.patientId, widget.doc['id'] as int);
    _bytes.ignore();
  }

  bool get _isImage => (widget.doc['mime_type'] as String?)?.startsWith('image/') ?? false;

  Future<void> _saveCopy(Uint8List bytes) async {
    final name = widget.doc['filename'] as String? ?? 'document';
    try {
      // Desktop returns the chosen path without writing; mobile writes via the
      // bytes parameter. Writing again on desktop is what actually saves it.
      final savePath = await FilePicker.saveFile(fileName: name, bytes: bytes);
      if (savePath == null) return;
      try {
        await File(savePath).writeAsBytes(bytes);
      } catch (_) {
        // On mobile the path may be a content URI already written by the plugin.
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved to $savePath')));
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
    final name = widget.doc['filename'] as String? ?? 'Document';
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return CenteredMessage(
              icon: Icons.error_outline,
              title: 'Could not open the document',
              subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
            );
          }
          final bytes = snap.data!;
          return Column(
            children: [
              Expanded(
                child: _isImage
                    ? InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 5,
                        child: Center(child: Image.memory(bytes)),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_iconForMime(widget.doc['mime_type'] as String?),
                                  size: 64, color: scheme.onSurfaceVariant),
                              const SizedBox(height: 16),
                              Text(name,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700, fontSize: 16)),
                              const SizedBox(height: 6),
                              Text(
                                '${formatBytes(bytes.length)} · preview not available for this type',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: () => _saveCopy(bytes),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save a copy'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
