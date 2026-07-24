// Widget test for the doctor Settings screen: profile fields prefill from
// the current session without any network call.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/doctor/doctor_settings_screen.dart';

void main() {
  setUp(() => MedThruApi.instance.debugSetSession(
        token: 'fake-token',
        doctor: {
          'id': 1,
          'name': 'Dr. Test',
          'email': 'test@medthru.test',
          'phone': '012-3456789',
        },
      ));
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Profile fields prefill from the signed-in doctor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: DoctorSettingsScreen()));

    expect(find.text('Dr. Test'), findsOneWidget);
    expect(find.text('test@medthru.test'), findsOneWidget);
    expect(find.text('012-3456789'), findsOneWidget);

    expect(find.widgetWithText(FilledButton, 'Save profile'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Change password'), findsOneWidget);
  });

  testWidgets('Save profile is disabled-safe: empty name shows an error, not a crash',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DoctorSettingsScreen()));

    await tester.enterText(find.widgetWithText(TextField, 'Name').hitTestable(), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save profile'));
    await tester.pump();

    expect(find.text('Name and email are required.'), findsOneWidget);
  });
}
