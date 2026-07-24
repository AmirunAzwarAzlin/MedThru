// Smoke test for the doctor dashboard. The data path fetches over the network,
// which the test binding stubs with a 400, so this exercises the load → error
// path and confirms the screen builds and degrades gracefully with a retry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/doctor/doctor_dashboard_screen.dart';
import 'package:medthru_app/theme.dart';

void main() {
  setUp(() => MedThruApi.instance.debugSetSession(
        token: 'fake-token',
        doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test'},
      ));
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Dashboard loads, then shows a graceful error with retry',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: MedThruTheme.light(),
      home: const Scaffold(
        body: DoctorDashboardScreen(doctorName: 'Dr. Joanne Carter'),
      ),
    ));

    // Starts in a loading state.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The stubbed network returns 400, so the future rejects and the screen
    // settles into an error with a way to retry.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Could not load the dashboard'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
