// Widget tests for the Health Records screen: tapping its Home dashboard
// tile opens the nine-category menu, and tapping a category navigates to
// its dedicated page. Network calls inside the pushed screens are left to
// fail (no server in the test environment) and settle into their error
// state, same pattern as dashboard_golden_test.dart — these tests check
// structure, not data.
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

  testWidgets('Health Records screen lists all nine categories', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Health Records').first);
    await tester.pumpAndSettle();

    expect(find.text('Allergies & intolerances'), findsOneWidget);
    expect(find.text('Anthropometry'), findsOneWidget);
    expect(find.text('Medical history'), findsOneWidget);
    expect(find.text('Medications'), findsOneWidget);
    expect(find.text('Vaccinations'), findsOneWidget);
    expect(find.text('Lab results'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Emergency contacts'), findsOneWidget);
    expect(find.text('Vital signs'), findsOneWidget);
  });

  testWidgets('Tapping a category opens its own page with an Add action', (tester) async {
    // A tall surface so the Home dashboard's Health Records tile sits within
    // the viewport (the emergency band + vitals push it past a 600px height).
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: PatientScreen(patient: _patient, cardToken: 'fake-token'),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Health Records').first);
    await tester.pumpAndSettle();

    // "Allergies & intolerances" appears twice once pushed (menu row title
    // is gone since it's a new route, but the AppBar title matches it), so
    // scope to the tile then push.
    await tester.tap(find.text('Allergies & intolerances'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Allergies & intolerances'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'Add'), findsOneWidget);

    // The category page's own FAB opens the add screen (not the edit form,
    // since none is preselected).
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Add allergy / intolerance'), findsOneWidget);
  });
}
