import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/main.dart';
import 'package:medthru_app/api.dart';

void main() {
  // Every test starts signed out.
  setUp(() => MedThruApi.instance.debugSetSession());
  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Landing page renders when signed out', (tester) async {
    await tester.pumpWidget(const MedThruApp(enableTapListening: false, enableNotifications: false));

    // The landing page is the hero, the two call-to-action buttons and the
    // disclaimer — the "Why Med-IC" and "How it works" sections were dropped.
    expect(find.text('NFC MEDICAL CARD'), findsOneWidget);
    expect(find.textContaining('readable in a tap'), findsOneWidget);

    // Signed out: both sign-in routes offered, no doctor tools, no logout.
    expect(find.text('Log in with phone'), findsOneWidget);
    expect(find.text('Doctor sign in'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.text('Register patient'), findsNothing);
  });

  // Regression test: the home screen must rebuild when auth state changes.
  // It previously did not, because main.dart returned a `const HomeScreen()`
  // from an AnimatedBuilder, which Flutter skips re-rendering.
  testWidgets('Home reacts to sign in and sign out', (tester) async {
    await tester.pumpWidget(const MedThruApp(enableTapListening: false, enableNotifications: false));
    // Signed out: no doctor navigation, sign-in offered.
    expect(find.byIcon(Icons.people_outline), findsNothing);
    expect(find.text('Doctor sign in'), findsOneWidget);

    // Simulate signing in.
    MedThruApi.instance.debugSetSession(
      token: 'fake-token',
      doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test'},
    );
    await tester.pump();

    // Signed in: a doctor now lands on the dashboard, with the practice
    // navigation and account menu in the app bar. The dashboard body loads
    // over the network, so we assert on this chrome rather than its contents.
    expect(find.byIcon(Icons.people_outline), findsOneWidget); // Patients
    expect(find.byIcon(Icons.event_note_outlined), findsOneWidget); // Requests
    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget); // Account
    expect(find.text('Doctor sign in'), findsNothing);

    // Signing out via the account menu returns the page to its signed-out
    // state. (Timed pumps, not pumpAndSettle: the loading dashboard shows an
    // indeterminate spinner that never settles.)
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Sign out'));
    await tester.pump();

    expect(find.byIcon(Icons.people_outline), findsNothing);
    expect(find.text('Doctor sign in'), findsOneWidget);
  });
}
