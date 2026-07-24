// Widget tests for the trimmed-down PatientScreen navigation: the tab bar
// only has Home/Profile/Emergency/Settings, Care Plan/Appointments/Health
// Records/Updates are Home-dashboard-only pushed screens, and the Profile
// tile is gone from Home now that Profile itself stays a tab.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/patient/patient_screen.dart';

final _patient = <String, dynamic>{
  'id': 1,
  'full_name': 'Amelia Tan',
  'card_preview': 'C3D4',
  'card_id': 1,
};

void main() {
  setUp(() => MedThruApi.instance.debugSetSession());
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Tab bar only has Home, Profile, Emergency and Settings', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Tab), findsNWidgets(4));
    expect(find.text('Settings'), findsOneWidget);
    // These used to be tabs; they're Home-dashboard tiles only now.
    expect(find.widgetWithText(Tab, 'Care plan'), findsNothing);
    expect(find.widgetWithText(Tab, 'Appointments'), findsNothing);
    expect(find.widgetWithText(Tab, 'Health Records'), findsNothing);
    expect(find.widgetWithText(Tab, 'Updates'), findsNothing);
  });

  testWidgets('Home dashboard has an Appointments tile but no Profile tile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Appointments'), findsOneWidget);
    // "Profile" only appears once now: the tab itself, not a dashboard tile.
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('Settings tab offers Sign out for a phone session, not a real card',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'me'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);
  });

  testWidgets('Settings tab has no Sign out for a real card token', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'real-card-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsNothing);
  });
}
