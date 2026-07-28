import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'file_share.dart';

/// Exports a booked appointment as an .ics calendar event so a patient can
/// drop it into whatever calendar app they use. Deliberately a plain iCalendar
/// file — no account linking, no server round-trip — matching the app's other
/// "save a file and let the OS open it" exports (see `pdf_export.dart`).
///
/// The appointment [starts_at] is a clinic-local wall-clock string
/// ("YYYY-MM-DD HH:MM"), the same "read it off a signboard" time used
/// throughout the app. We emit it as a floating local time (no Z, no VTIMEZONE)
/// so a calendar app shows it at that exact clock time — correct for a
/// single-country app and simpler than carrying a timezone database.

/// A 30-minute default slot: the appointment table doesn't store a length, and
/// 30 minutes matches the common clinic slot used elsewhere.
const Duration _defaultDuration = Duration(minutes: 30);

/// Builds, saves and opens a calendar event for one appointment.
Future<void> exportAppointmentToCalendar(
  BuildContext context,
  Map<String, dynamic> appt,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ics = buildAppointmentIcs(appt);
    final fileName = 'medic-appointment-${appt['id']}-'
        '${DateTime.now().millisecondsSinceEpoch}.ics';
    final saved = await saveAndOpen(
      Uint8List.fromList(utf8.encode(ics)),
      fileName,
      mimeType: 'text/calendar',
      shareText: 'Appointment at ${appt['clinic_name'] ?? 'the clinic'}',
    );
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(saved.shared ? 'Ready to add to your calendar' : 'Saved to ${saved.path}'),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Could not export: ${e.toString().replaceFirst('Exception: ', '')}',
        ),
      ),
    );
  }
}

/// Assembles the iCalendar text for [appt]. Public so it can be unit-tested
/// without touching the filesystem.
String buildAppointmentIcs(Map<String, dynamic> appt) {
  final startsAt = appt['starts_at'] as String;
  final start = DateTime.parse(startsAt.replaceFirst(' ', 'T'));
  final end = start.add(_defaultDuration);

  final clinic = (appt['clinic_name'] as String?) ?? 'Clinic';
  final status = appt['status'] as String?;
  final reason = appt['reason'] as String?;
  final note = appt['decision_note'] as String?;

  final description = [
    if (status != null && status.isNotEmpty) 'Status: ${_titleCase(status)}',
    if (reason != null && reason.isNotEmpty) 'Reason: $reason',
    if (note != null && note.isNotEmpty) 'Clinic note: $note',
    'Booked with Med-IC.',
    // Real newlines here; _escape() turns each into the iCalendar '\n' escape.
  ].join('\n');

  // DTSTAMP must be UTC; DTSTART/DTEND stay floating local (the clinic clock).
  final stamp = _icsUtc(DateTime.now().toUtc());
  final uid = 'medthru-appt-${appt['id']}@medthru';

  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Med-IC//Appointment//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    'UID:$uid',
    'DTSTAMP:$stamp',
    'DTSTART:${_icsLocal(start)}',
    'DTEND:${_icsLocal(end)}',
    'SUMMARY:${_escape('Appointment at $clinic')}',
    'LOCATION:${_escape(clinic)}',
    'DESCRIPTION:${_escape(description)}',
    // Nudge an hour ahead, mirroring the in-app reminder default.
    'BEGIN:VALARM',
    'TRIGGER:-PT1H',
    'ACTION:DISPLAY',
    'DESCRIPTION:${_escape('Upcoming appointment at $clinic')}',
    'END:VALARM',
    'END:VEVENT',
    'END:VCALENDAR',
  ];

  // iCalendar wants CRLF line endings.
  return '${lines.join('\r\n')}\r\n';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Floating local time: 20260714T082000 (no trailing Z).
String _icsLocal(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}'
    'T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';

/// UTC instant: 20260714T002000Z.
String _icsUtc(DateTime d) => '${_icsLocal(d)}Z';

/// Escapes the characters iCalendar treats specially in text values.
String _escape(String s) => s
    .replaceAll('\\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll(',', r'\,')
    .replaceAll(';', r'\;');

String _titleCase(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
