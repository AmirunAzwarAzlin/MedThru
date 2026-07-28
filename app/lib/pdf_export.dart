import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'api.dart';
import 'file_share.dart';

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
    final saved = await _saveAndOpen(bytes, patient['full_name'] as String? ?? 'patient');

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close the spinner
    messenger.showSnackBar(SnackBar(
      content: Text(saved.shared ? 'Emergency summary ready to share' : 'Saved to ${saved.path}'),
    ));
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export: ${e.toString().replaceFirst('Exception: ', '')}')),
    );
  }
}

/// Builds, saves and opens a prescription for [patient]: the medications a
/// doctor has added to their record (source = 'doctor'), on a prescription-style
/// sheet with the prescriber's name and a signature line. Doctor-facing.
Future<void> exportPrescription(BuildContext context, Map<String, dynamic> patient) async {
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  try {
    final patientId = patient['id'] as int;
    final meds = await MedThruApi.instance.getMedicationsForPatient(patientId);
    // A prescription is what a clinician has prescribed; fall back to the full
    // list only if nothing is tagged doctor-added, so the sheet is never empty
    // when there genuinely are current medications.
    final prescribed = meds.where((m) => m['source'] == 'doctor').toList();
    final items = prescribed.isEmpty ? meds : prescribed;

    final bytes = await _buildPrescriptionPdf(
      patient: patient,
      medications: items,
      prescriber: MedThruApi.instance.doctorName ?? 'Attending doctor',
    );
    final saved = await _saveAndOpen(
      bytes,
      patient['full_name'] as String? ?? 'patient',
      kind: 'prescription',
    );

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(saved.shared ? 'Prescription ready to share' : 'Saved to ${saved.path}'),
    ));
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export: ${e.toString().replaceFirst('Exception: ', '')}')),
    );
  }
}

Future<Uint8List> _buildPrescriptionPdf({
  required Map<String, dynamic> patient,
  required List<Map<String, dynamic>> medications,
  required String prescriber,
}) async {
  final doc = pw.Document();
  final generated = DateTime.now();
  final dateStr = '${generated.year.toString().padLeft(4, '0')}-'
      '${generated.month.toString().padLeft(2, '0')}-'
      '${generated.day.toString().padLeft(2, '0')}';

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
              pw.Text('Med-IC - Prescription',
                  style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.Text(dateStr,
                  style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text(val('full_name'),
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Divider(color: PdfColors.grey400),
          pw.SizedBox(height: 8),
          _row('Date of birth', val('date_of_birth')),
          _row('Prescriber', prescriber),
          pw.SizedBox(height: 16),
          _heading('PRESCRIBED MEDICATIONS'),
          pw.SizedBox(height: 6),
          if (medications.isEmpty)
            pw.Text('No prescribed medications on file.',
                style: const pw.TextStyle(color: PdfColors.grey700))
          else
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < medications.length; i++)
                  _prescriptionItem(i + 1, medications[i]),
              ],
            ),
          pw.Spacer(),
          pw.SizedBox(height: 24),
          pw.Container(
            width: 200,
            decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: PdfColors.grey600)),
            ),
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(prescriber, style: const pw.TextStyle(fontSize: 11)),
          ),
          pw.Text('Signature & date',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
          pw.SizedBox(height: 10),
          pw.Divider(color: PdfColors.grey400),
          pw.Text(
            'Generated by Med-IC - prototype, for demonstration only. Not a valid '
            'prescription for dispensing.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _prescriptionItem(int n, Map<String, dynamic> m) {
  final dosage = m['dosage'] as String?;
  final frequency = m['frequency'] as String?;
  final start = m['start_date'] as String?;
  final end = m['end_date'] as String?;
  final detail = [
    if (dosage != null && dosage.isNotEmpty) dosage,
    if (frequency != null && frequency.isNotEmpty) frequency,
  ].join(' - ');
  final range = (start == null && end == null)
      ? null
      : 'From ${start ?? '-'} to ${end ?? 'ongoing'}';
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('$n. ${m['name']}',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        if (detail.isNotEmpty)
          pw.Text(detail, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800)),
        if (range != null)
          pw.Text(range, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
      ],
    ),
  );
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

/// Writes the PDF out and hands it to the OS — opened with the default viewer
/// on desktop (so printing happens there), or offered through the share sheet
/// on Android/iOS. See `file_share.dart` for the platform split.
Future<SavedExport> _saveAndOpen(Uint8List bytes, String patientName, {String kind = 'summary'}) async {
  final safeName = patientName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  final fileName = 'medic-$kind-${safeName.isEmpty ? 'patient' : safeName}-'
      '${DateTime.now().millisecondsSinceEpoch}.pdf';
  return saveAndOpen(bytes, fileName, mimeType: 'application/pdf');
}
