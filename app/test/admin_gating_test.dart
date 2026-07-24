// Widget test: card reissue is administrator-only now, not every doctor.
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
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('A signed-in doctor without admin rights has no Reissue card action',
      (tester) async {
    MedThruApi.instance.debugSetSession(
      token: 'fake-token',
      doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test', 'is_admin': false},
    );

    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Reissue card (lost or stolen)'), findsNothing);
    // Access history stays doctor-only, unaffected by admin status.
    expect(find.byTooltip('Access history'), findsOneWidget);
  });

  testWidgets('An administrator sees the Reissue card action', (tester) async {
    MedThruApi.instance.debugSetSession(
      token: 'fake-token',
      doctor: {'id': 1, 'name': 'Dr. Admin', 'email': 'admin@medthru.test', 'is_admin': true},
    );

    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Reissue card (lost or stolen)'), findsOneWidget);
  });
}
