// Renders the Sparkline to a PNG for visual review — the "render it and look"
// step. Regenerate with: flutter test --update-goldens test/sparkline_golden_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/theme.dart';
import 'package:medthru_app/trend_chart.dart';

void main() {
  testWidgets('sparkline renders a trend with a typical-range band', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: MedThruTheme.light(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              // Trending back into range (out at first, ending within).
              Sparkline(
                values: [138, 142, 133, 128, 126, 121, 118],
                color: Color(0xFF5B8DEF),
                low: 90,
                high: 120,
                width: 160,
                height: 48,
              ),
              SizedBox(height: 24),
              Sparkline(
                values: [6.8, 6.9, 6.4, 6.1, 5.8, 5.6],
                color: Color(0xFF6C63C7),
                low: 4.0,
                high: 5.6,
                width: 160,
                height: 48,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Column),
      matchesGoldenFile('goldens/sparkline.png'),
    );
  });
}
