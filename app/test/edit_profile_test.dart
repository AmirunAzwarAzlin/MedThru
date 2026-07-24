// Widget tests for the patient self-editing their own name/date of birth:
// the Profile tab's edit affordance, and the edit screen's own prefill.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/patient/edit_profile_screen.dart';
import 'package:medthru_app/screens/patient/patient_screen.dart';

final _patient = <String, dynamic>{
  'id': 1,
  'full_name': 'Amelia Tan',
  'date_of_birth': '1998-10-01',
  'card_preview': 'C3D4',
  'card_id': 1,
};

void main() {
  setUp(() => MedThruApi.instance.debugSetSession());
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Profile tab offers an edit action to a patient, not a doctor', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Edit name / date of birth'), findsOneWidget);
  });

  testWidgets('EditProfileScreen prefills name and date of birth', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: EditProfileScreen(token: 'fake-token', patient: _patient),
    ));

    expect(find.text('Amelia Tan'), findsOneWidget);
    expect(find.text('1998-10-01'), findsOneWidget);
  });

  testWidgets('EditProfileScreen rejects a blank name before saving', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: EditProfileScreen(token: 'fake-token', patient: _patient),
    ));

    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(find.text('Name cannot be blank.'), findsOneWidget);
  });
}
