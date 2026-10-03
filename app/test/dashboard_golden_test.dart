// Renders the patient dashboard to PNGs for visual review.
// Regenerate with: flutter test --update-goldens test/dashboard_golden_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/theme.dart';
import 'package:medthru_app/screens/patient/patient_screen.dart';

final _patient = <String, dynamic>{
  'id': 1,
  'full_name': 'Amelia Tan',
  'date_of_birth': '1998-10-01',
  'blood_type': 'O+',
  'allergies': 'Penicillin',
  'medications': 'Azithromycin 500mg daily',
  'conditions': 'Mild asthma',
  'emergency_contact_name': 'Tan Wei',
  'emergency_contact_phone': '+60123456789',
  'next_appointment': '2026-08-15',
  'surgery_date': null,
  'primary_doctor': 'Dr. Sarah Lim',
  'card_preview': 'C3D4',
  'card_id': 1,
  'updated_at': '2026-07-10 10:08:00',
};

/// Pinned so the Home calendar always renders the same month. Without this the
/// goldens encode whatever month the suite happened to run in, and go red on
/// the 1st.
final _today = DateTime(2026, 7, 21);

void main() {
  setUp(() => MedThruApi.instance.debugSetSession());

  for (final (name, theme) in [
    ('light', MedThruTheme.light()),
    ('dark', MedThruTheme.dark()),
  ]) {
    testWidgets('patient dashboard - $name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        home: PatientScreen(
          patient: _patient,
          cardToken: 'fake-token',
          today: _today,
        ),
      ));
      // The Readings/Notes futures will fail (no server); let them settle.
      await tester.pump(const Duration(milliseconds: 100));

      // A raw card token now lands on the Emergency tab by default, which
      // scrolls the (isScrollable) tab bar to center it — pushing "Home" off
      // the visible strip at this width, so bring it into view before
      // tapping. This golden is specifically of the Home dashboard.
      await tester.ensureVisible(find.text('Home'));
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/dashboard_$name.png'),
      );
    });
  }
}
