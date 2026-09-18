// Widget test for RescheduleScreen: confirms it renders in both patient and
// doctor mode and shows a loading state before the suggestions future
// resolves, without requiring a real network call.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/appointments/reschedule_screen.dart';

void main() {
  final appointment = {
    'id': 1,
    'starts_at': '2026-09-25 10:00',
    'clinic_name': 'Test Clinic',
    'status': 'confirmed',
  };

  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Patient mode shows a loading indicator before suggestions arrive',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RescheduleScreen(appointment: appointment, cardToken: 'fake-card-token'),
    ));

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Reschedule appointment'), findsOneWidget);
  });

  testWidgets('Doctor mode shows a loading indicator before suggestions arrive',
      (tester) async {
    MedThruApi.instance.debugSetSession(
      token: 'fake-doctor-token',
      doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test'},
    );
    await tester.pumpWidget(MaterialApp(
      home: RescheduleScreen(appointment: appointment, cardToken: null),
    ));

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Reschedule appointment'), findsOneWidget);
  });
}
