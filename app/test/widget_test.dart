import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/main.dart';
import 'package:medthru_app/api.dart';

void main() {
  // Every test starts signed out.
  setUp(() => MedThruApi.instance.debugSetSession());
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Landing page renders when signed out', (tester) async {
    await tester.pumpWidget(const MedThruApp());

    expect(find.textContaining('readable in a tap'), findsOneWidget);
    expect(find.text('Why Med-IC'), findsOneWidget);
    expect(find.text('How it works'), findsOneWidget);
    expect(find.text('Read a card'), findsOneWidget);

    // Signed out: sign-in offered, no doctor tools, no logout.
    expect(find.text('Doctor sign in'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.text('Register new patient'), findsNothing);
  });

  // Regression test: the home screen must rebuild when auth state changes.
  // It previously did not, because main.dart returned a `const HomeScreen()`
  // from an AnimatedBuilder, which Flutter skips re-rendering.
  testWidgets('Home reacts to sign in and sign out', (tester) async {
    await tester.pumpWidget(const MedThruApp());
    expect(find.byIcon(Icons.logout), findsNothing);

    // Simulate signing in.
    MedThruApi.instance.debugSetSession(
      token: 'fake-token',
      doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test'},
    );
    await tester.pump();

    expect(find.byIcon(Icons.logout), findsOneWidget);
    expect(find.text('Signed in as Dr. Test'), findsOneWidget);
    expect(find.text('Register new patient'), findsOneWidget);
    expect(find.text('Doctor sign in'), findsNothing);

    // Tapping logout returns the page to its signed-out state.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pump();

    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.text('Doctor sign in'), findsOneWidget);
  });
}
