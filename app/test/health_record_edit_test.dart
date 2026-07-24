// Widget tests for the health-record "edit mode": passing an existing row
// prefills the form and swaps the title/action from Add to Edit, instead of
// creating a duplicate entry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/screens/health_records/add_allergy_screen.dart';
import 'package:medthru_app/screens/health_records/add_medical_history_screen.dart';
import 'package:medthru_app/screens/health_records/add_emergency_contact_screen.dart';

void main() {
  testWidgets('AddAllergyScreen with no existing entry is in add mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AddAllergyScreen(token: 'fake-token'),
    ));

    expect(find.widgetWithText(AppBar, 'Add allergy / intolerance'), findsOneWidget);
    expect(find.text(''), findsWidgets); // fields start empty; no crash reading `existing`
  });

  testWidgets('AddAllergyScreen prefills from an existing entry and switches to edit mode',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AddAllergyScreen(
        token: 'fake-token',
        existing: {
          'id': 7,
          'allergen': 'Penicillin',
          'reaction': 'Rash',
          'severity': 'Moderate',
          'note': 'Confirmed by allergist',
        },
      ),
    ));

    expect(find.widgetWithText(AppBar, 'Edit allergy / intolerance'), findsOneWidget);
    expect(find.text('Penicillin'), findsOneWidget);
    expect(find.text('Rash'), findsOneWidget);
    expect(find.text('Confirmed by allergist'), findsOneWidget);

    // The matching severity chip is pre-selected.
    final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Moderate'));
    expect(chip.selected, isTrue);
  });

  testWidgets('AddMedicalHistoryScreen prefills status from the stored lowercase value',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AddMedicalHistoryScreen(
        token: 'fake-token',
        existing: {
          'id': 3,
          'condition_name': 'Hypertension',
          'diagnosed_at': '2025-01-10',
          'status': 'resolved',
          'note': null,
        },
      ),
    ));

    expect(find.widgetWithText(AppBar, 'Edit medical history'), findsOneWidget);
    expect(find.text('Hypertension'), findsOneWidget);

    final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Resolved'));
    expect(chip.selected, isTrue);
  });

  testWidgets('AddEmergencyContactScreen prefills from an existing contact', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AddEmergencyContactScreen(
        token: 'fake-token',
        existing: {
          'id': 5,
          'name': 'Aiman Roslan',
          'phone': '012-1112222',
          'relationship': 'Sibling',
          'note': null,
        },
      ),
    ));

    expect(find.widgetWithText(AppBar, 'Edit emergency contact'), findsOneWidget);
    expect(find.text('Aiman Roslan'), findsOneWidget);
    expect(find.text('012-1112222'), findsOneWidget);

    final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Sibling'));
    expect(chip.selected, isTrue);
  });

  testWidgets('AddEmergencyContactScreen with no existing entry is in add mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AddEmergencyContactScreen(token: 'fake-token'),
    ));

    expect(find.widgetWithText(AppBar, 'Add emergency contact'), findsOneWidget);
  });
}
