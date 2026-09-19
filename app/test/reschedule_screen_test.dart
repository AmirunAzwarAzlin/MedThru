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

  testWidgets(
      'A suggestion card with a long AI rationale renders without a layout error',
      (tester) async {
    // Regression test: ListTile.trailing throws a layout exception once the
    // title/subtitle text is long enough to leave the trailing FilledButton
    // no room, and real Gemini-generated rationale text routinely is this
    // long. SuggestionCard replaced ListTile specifically to avoid this.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SuggestionCard(
          suggestion: const {
            'startsAt': '2026-09-22 09:20',
            'rationale':
                'This slot keeps your routine appointment on the same day, just '
                    'slightly earlier, so your care stays right on schedule.',
          },
          onChoose: () {},
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Choose'), findsOneWidget);
    expect(
      find.textContaining('keeps your routine appointment'),
      findsOneWidget,
    );
  });
}
