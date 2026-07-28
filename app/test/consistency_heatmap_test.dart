// app/test/consistency_heatmap_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medthru_app/screens/patient/consistency_heatmap.dart';
import 'package:medthru_app/theme.dart';

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> readings) {
  return tester.pumpWidget(MaterialApp(
    theme: MedThruTheme.light(),
    home: Scaffold(body: ConsistencyHeatmapCard(readings: readings)),
  ));
}

void main() {
  testWidgets('shows the empty caption when there is no history', (tester) async {
    await _pump(tester, const []);
    expect(find.text('Your logging history will fill in here'), findsOneWidget);
  });

  testWidgets('renders the section heading with readings present', (tester) async {
    await _pump(tester, [
      {
        'reading_type': 'blood_sugar',
        'value': 5.4,
        'taken_at': DateTime.now().toIso8601String(),
      },
    ]);
    expect(find.text('LOGGING ACTIVITY'), findsOneWidget);
    expect(find.text('Your logging history will fill in here'), findsNothing);
  });
}
