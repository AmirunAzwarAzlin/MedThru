// Widget tests for the patient phone-login path: the entry point on the
// home screen, and the login screen's own fields.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/main.dart';
import 'package:medthru_app/screens/auth/patient_login_screen.dart';

void main() {
  setUp(() => MedThruApi.instance.debugSetSession());
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Home screen offers "Log in with phone" when signed out', (tester) async {
    await tester.pumpWidget(const MedThruApp(enableTapListening: false, enableNotifications: false));

    expect(find.text('Log in with phone'), findsOneWidget);

    await tester.tap(find.text('Log in with phone'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Log in with phone'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2)); // phone + password
  });

  testWidgets('Patient login screen has phone and password fields', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PatientLoginScreen()));

    final phoneField = find.byType(TextField).at(0);
    final passwordField = find.byType(TextField).at(1);
    expect(phoneField, findsOneWidget);
    expect(passwordField, findsOneWidget);

    final password = tester.widget<TextField>(passwordField);
    expect(password.obscureText, isTrue);

    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
  });
}
