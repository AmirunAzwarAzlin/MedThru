// Renders the trend chart to PNGs so its geometry can be inspected.
// Regenerate with:  flutter test --update-goldens test/chart_golden_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/readings.dart';
import 'package:medthru_app/theme.dart';
import 'package:medthru_app/trend_chart.dart';

List<TrendPoint> _series(List<double> values, int everyDays) {
  final start = DateTime(2026, 4, 20);
  return [
    for (var i = 0; i < values.length; i++)
      (t: start.add(Duration(days: i * everyDays)), v: values[i]),
  ];
}

// Mirrors the seeded data: sugar improving, cholesterol crossing its ceiling.
final bloodSugar = _series(
  [7.7, 7.1, 7.0, 6.7, 6.3, 6.2, 5.9, 5.5, 5.4, 5.1, 4.7, 4.9],
  7,
);
final cholesterol = _series([4.7, 4.9, 5.0, 5.3, 5.4, 5.6], 14);
final uricAcid = _series([390, 448, 466, 419, 383, 407], 14);

Widget _harness(ThemeData theme) {
  return MaterialApp(
    theme: theme,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: Container(
          width: 420,
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                (readingTypes['blood_sugar']!, bloodSugar),
                (readingTypes['cholesterol']!, cholesterol),
                (readingTypes['uric_acid']!, uricAcid),
              ]) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${entry.$1.label}  (${entry.$1.unit})',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                TrendChart(points: entry.$2, spec: entry.$1),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('trend chart - light', (tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 790));
    await tester.pumpWidget(_harness(MedThruTheme.light()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/trend_light.png'),
    );
  });

  testWidgets('trend chart - dark', (tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 790));
    await tester.pumpWidget(_harness(MedThruTheme.dark()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/trend_dark.png'),
    );
  });
}
