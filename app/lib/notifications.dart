import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Local, on-device medication and appointment reminders.
///
/// Deliberately client-side only: a reminder is "buzz me on this phone at
/// this time", not clinical data, so it never touches the server and isn't
/// synced across devices. Where the reminder time itself is persisted (so it
/// survives an app restart) is the caller's concern — see
/// `medication_reminders.dart` and the appointment reminder toggle in
/// `appointments_screen.dart`.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Fixed per-kind offsets so a medication id and an appointment id can
  // never collide over the same underlying OS notification id.
  static const _medicationIdBase = 200000;
  static const _appointmentIdBase = 300000;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    tz.initializeTimeZones();
    // The plugin's own example skips this on Windows, but that leaves
    // `tz.local` at UTC — a reminder picked for "07:06" then fires at 07:06
    // UTC, not 07:06 local time. flutter_timezone does support Windows
    // (declared in its pubspec), so there's no reason to special-case it.
    if (!kIsWeb && !Platform.isLinux) {
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {
        // Falls back to UTC — reminders still fire, just not necessarily at
        // the exact wall-clock time picked.
      }
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windowsInit = WindowsInitializationSettings(
      appName: 'MedThru',
      appUserModelId: 'Com.MedThru.App',
      guid: '8f2b1a2e-2f0a-4b7e-9c1a-4d2f6a7b9c3d',
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        windows: windowsInit,
      ),
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  static const _medicationChannel = AndroidNotificationDetails(
    'medication_reminders',
    'Medication reminders',
    channelDescription: 'Reminders to take a logged medication.',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const _appointmentChannel = AndroidNotificationDetails(
    'appointment_reminders',
    'Appointment reminders',
    channelDescription: 'Reminders before a booked appointment.',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Schedules a daily repeating reminder at [hour]:[minute] (local time).
  Future<void> scheduleMedicationReminder({
    required int medicationId,
    required String name,
    String? dosage,
    required int hour,
    required int minute,
  }) async {
    await init();
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (scheduled.isBefore(now)) scheduled = scheduled.add(const Duration(days: 1));

    await _plugin.zonedSchedule(
      id: _medicationIdBase + medicationId,
      title: 'Time to take $name',
      body: (dosage == null || dosage.isEmpty) ? null : dosage,
      scheduledDate: scheduled,
      notificationDetails: const NotificationDetails(
        android: _medicationChannel,
        windows: WindowsNotificationDetails(
          scenario: WindowsNotificationScenario.reminder,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> cancelMedicationReminder(int medicationId) async {
    await _plugin.cancel(id: _medicationIdBase + medicationId);
  }

  /// Schedules a one-off reminder [lead] before [startsAt]. Does nothing if
  /// that moment has already passed — nothing useful to remind at that point.
  Future<void> scheduleAppointmentReminder({
    required int appointmentId,
    required String clinicName,
    required DateTime startsAt,
    Duration lead = const Duration(hours: 1),
  }) async {
    await init();
    final fireAt = tz.TZDateTime.from(startsAt.subtract(lead), tz.local);
    if (fireAt.isBefore(tz.TZDateTime.now(tz.local))) return;

    await _plugin.zonedSchedule(
      id: _appointmentIdBase + appointmentId,
      title: 'Upcoming appointment',
      body: 'At $clinicName ${_leadText(lead)}',
      scheduledDate: fireAt,
      notificationDetails: const NotificationDetails(
        android: _appointmentChannel,
        windows: WindowsNotificationDetails(
          scenario: WindowsNotificationScenario.reminder,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> cancelAppointmentReminder(int appointmentId) async {
    await _plugin.cancel(id: _appointmentIdBase + appointmentId);
  }

  String _leadText(Duration d) {
    if (d.inMinutes < 60) return 'in ${d.inMinutes} minutes';
    if (d.inMinutes % 60 == 0) return 'in ${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    return 'in ${d.inHours}h ${d.inMinutes % 60}m';
  }
}
