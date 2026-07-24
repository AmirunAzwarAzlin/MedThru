import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'api.dart';

/// Builds, saves and opens a one-page emergency summary for [patient] - the
/// essentials a first responder needs, the same framing as the app's own
/// Emergency tab. Self-contained: fetches the structured allergy and
/// medication lists itself, so any screen holding a patient id can call it.
Future<void> exportPatientSummary(BuildContext context, Map<String, dynamic> patient) async {
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  try {
    final patientId = patient['id'] as int;
    final allergies = await MedThruApi.instance.getAllergiesForPatient(patientId);
    final medications = await MedThruApi.instance.getMedicationsForPatient(patientId);

    final bytes = await _buildSummaryPdf(
      patient: patient,
      allergies: allergies,
      medications: medications,
    );
    final path = await _saveAndOpen(bytes, patient['full_name'] as String? ?? 'patient');

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close the spinner
    messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export: ${e.toString().replaceFirst('Exception: ', '')}')),
    );
  }
}

Future<Uint8List> _buildSummaryPdf({
  required Map<String, dynamic> patient,
  required List<Map<String, dynamic>> allergies,
  required List<Map<String, dynamic>> medications,
}) async {
  final doc = pw.Document();
  final generated = DateTime.now();

  String val(String key) {
    final v = patient[key];
    return (v == null || (v is String && v.isEmpty)) ? '-' : v.toString();
  }

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Med-IC - Emergency Summary',
                  style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.Text(
                '${generated.year.toString().padLeft(4, '0')}-'
                '${generated.month.toString().padLeft(2, '0')}-'
                '${generated.day.toString().padLeft(2, '0')}',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text(val('full_name'),
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Divider(color: PdfColors.grey400),
          pw.SizedBox(height: 8),
          _row('Date of birth', val('date_of_birth')),
          _row('Blood type', val('blood_type')),
          _row('Primary doctor', val('primary_doctor')),
          _row('Emergency contact',
              '${val('emergency_contact_name')} - ${val('emergency_contact_phone')}'),
          pw.SizedBox(height: 16),
          _heading('ALLERGIES & INTOLERANCES'),
          pw.SizedBox(height: 4),
          if (allergies.isEmpty)
            pw.Text('None recorded.', style: const pw.TextStyle(color: PdfColors.grey700))
          else
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final a in allergies)
                  pw.Bullet(
                    text: [
                      a['allergen'],
                      if (a['severity'] != null) '(${a['severity']})',
                      if (a['reaction'] != null) '- ${a['reaction']}',
                    ].join(' '),
                  ),
              ],
            ),
          pw.SizedBox(height: 16),
          _heading('MEDICATIONS'),
          pw.SizedBox(height: 4),
          if (medications.isEmpty)
            pw.Text('None recorded.', style: const pw.TextStyle(color: PdfColors.grey700))
          else
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final m in medications)
                  pw.Bullet(
                    text: [
                      m['name'],
                      if (m['dosage'] != null) m['dosage'],
                      if (m['frequency'] != null) '- ${m['frequency']}',
                    ].join(' '),
                  ),
              ],
            ),
          pw.SizedBox(height: 16),
          _heading('CONDITIONS'),
          pw.SizedBox(height: 4),
          pw.Text(val('conditions')),
          pw.Spacer(),
          pw.Divider(color: PdfColors.grey400),
          pw.Text(
            'Generated by Med-IC - prototype, for demonstration only. Not a substitute '
            'for direct confirmation with the patient\'s clinical record.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _heading(String text) => pw.Text(
      text,
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, letterSpacing: 1),
    );

pw.Widget _row(String label, String value) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.SizedBox(
            width: 130,
            child: pw.Text(label, style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 10)),
          ),
          pw.Text(value, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );

/// Writes the PDF to the user's Downloads folder (falling back to their
/// home directory) and opens it with the OS default viewer, so printing
/// happens through that app rather than a bundled print dialog.
Future<String> _saveAndOpen(Uint8List bytes, String patientName) async {
  final home = Platform.environment['USERPROFILE'] ?? Directory.current.path;
  var dir = Directory('$home\\Downloads');
  if (!await dir.exists()) {
    dir = Directory(home);
  }

  final safeName = patientName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  final fileName = 'medic-summary-${safeName.isEmpty ? 'patient' : safeName}-'
      '${DateTime.now().millisecondsSinceEpoch}.pdf';
  final file = File('${dir.path}\\$fileName');
  await file.writeAsBytes(bytes);

  await Process.start('cmd', ['/c', 'start', '""', file.path], runInShell: true);
  return file.path;
}
