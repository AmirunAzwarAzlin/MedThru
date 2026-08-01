// app/test/activity_recap_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/screens/patient/activity_recap.dart';
import 'package:medthru_app/theme.dart';

Map<String, dynamic> r(String type, num value, String takenAt) =>
    {'reading_type': type, 'value': value, 'taken_at': takenAt};

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> readings) {
  return tester.pumpWidget(MaterialApp(
    theme: MedThruTheme.light(),
    home: Scaffold(body: ActivityRecapCard(readings: readings)),
  ));
}

void main() {
  testWidgets('shows the unlock line when there is too little data',
      (tester) async {
    await _pump(tester, const []);
    expect(find.textContaining('unlock your weekly recap'), findsOneWidget);
  });

  testWidgets('renders a tile per qualifying metric', (tester) async {
    final base = DateTime.now();
    String at(int daysAgo) =>
        base.subtract(Duration(days: daysAgo)).toIso8601String();
    await _pump(tester, [
      r('blood_sugar', 5.4, at(1)),
      r('blood_sugar', 5.6, at(2)),
      r('blood_sugar', 6.0, at(9)),
    ]);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('Blood sugar'), findsOneWidget);
    expect(find.textContaining('unlock your weekly recap'), findsNothing);
  });
}
